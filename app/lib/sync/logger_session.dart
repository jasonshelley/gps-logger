import 'dart:async';
import 'dart:typed_data';

import '../ble/protocol.dart';
import '../core/crc32.dart';

/// The radio link under a [LoggerSession]. The real one is Bluetooth LE
/// (`ble_link.dart`); tests use a fake logger.
abstract class LoggerTransport {
  /// TX notifications from the logger, one message each.
  Stream<Uint8List> get notifications;

  /// Fires once if the link drops.
  Future<void> get disconnected;

  /// Writes one command to RX, with response.
  Future<void> write(Uint8List data);
}

class TransferException implements Exception {
  TransferException(this.message, {this.retryable = true, this.loggerError});
  final String message;
  final bool retryable;

  /// The logger's ERROR code, when the logger refused the command.
  final int? loggerError;
  @override
  String toString() => message;
}

class ReceivedFile {
  const ReceivedFile(this.name, this.bytes, this.crc);
  final String name;
  final Uint8List bytes;
  final int crc;
}

/// Reassembles one file from DATA messages and checks it against END.
class FileReceiver {
  FileReceiver(this.name, this.size) : _buf = Uint8List(size);

  final String name;
  final int size;
  final Uint8List _buf;
  int received = 0;
  String? error;

  /// Adds one DATA chunk. Chunks must arrive in order with no gaps.
  void add(int offset, Uint8List bytes) {
    if (error != null) return;
    if (offset != received) {
      error = 'Data out of order at $offset (expected $received)';
      return;
    }
    if (offset + bytes.length > size) {
      error = 'More data than the file size';
      return;
    }
    _buf.setRange(offset, offset + bytes.length, bytes);
    received += bytes.length;
  }

  /// Checks the finished file against END. Throws on any mismatch.
  ReceivedFile finish(EndEvent end) {
    if (error != null) throw TransferException(error!);
    if (received != end.size || end.size != size) {
      throw TransferException('Got $received of ${end.size} bytes');
    }
    final crc = Crc32.of(_buf);
    if (crc != end.crc) {
      throw TransferException(
          'CRC mismatch: logger ${Crc32.hex(end.crc)}, phone ${Crc32.hex(crc)}');
    }
    return ReceivedFile(name, _buf, crc);
  }
}

class _Waiter {
  _Waiter(this.test, this.completer);
  final bool Function(LoggerEvent) test;
  final Completer<LoggerEvent> completer;
  Timer? timer;
}

/// Speaks the logger's protocol (docs/ble-protocol.md) over a [LoggerTransport].
class LoggerSession {
  LoggerSession(this.transport, {this.stallTimeout = const Duration(seconds: 15)}) {
    _sub = transport.notifications.listen(_onMessage);
    transport.disconnected.then((_) => _fail(TransferException('The logger disconnected')));
  }

  final LoggerTransport transport;
  final Duration stallTimeout;
  late final StreamSubscription<Uint8List> _sub;
  final _waiters = <_Waiter>[];
  List<FileEvent>? _listing;
  FileReceiver? _receiver;
  DateTime _lastDataAt = DateTime.now();
  void Function(int received, int total)? _onProgress;
  bool _closed = false;
  TransferException? _closedReason;

  int chunkSize = 15;
  int version = 0;

  void _onMessage(Uint8List bytes) {
    final LoggerEvent evt;
    try {
      evt = decodeEvent(bytes);
    } on ProtocolException {
      return; // ignore malformed messages; the CRC catches real damage
    }
    if (evt is DataEvent) {
      final r = _receiver;
      if (r == null) return;
      r.add(evt.offset, evt.bytes);
      _lastDataAt = DateTime.now();
      _onProgress?.call(r.received, r.size);
      return;
    }
    if (evt is FileEvent && _listing != null) {
      _listing!.add(evt);
      return;
    }
    for (final w in List.of(_waiters)) {
      if (w.test(evt)) {
        w.timer?.cancel();
        _waiters.remove(w);
        w.completer.complete(evt);
        return;
      }
    }
  }

  void _fail(TransferException e) {
    _closed = true;
    _closedReason = e;
    for (final w in _waiters) {
      w.timer?.cancel();
      if (!w.completer.isCompleted) w.completer.completeError(e);
    }
    _waiters.clear();
  }

  /// Registers interest in the next event matching [test]. Throws straight
  /// away if the link is already down.
  _Waiter _waitFor(bool Function(LoggerEvent) test, Duration timeout, String what) {
    if (_closed) throw _closedReason!;
    final w = _Waiter(test, Completer<LoggerEvent>());
    // Callers may fail before awaiting this (a write error); don't let that
    // surface as an unhandled error.
    w.completer.future.ignore();
    if (timeout > Duration.zero) {
      w.timer = Timer(timeout, () {
        _waiters.remove(w);
        if (!w.completer.isCompleted) {
          w.completer.completeError(TransferException('Timed out waiting for $what'));
        }
      });
    }
    _waiters.add(w);
    return w;
  }

  void _dropWaiters() {
    for (final w in _waiters) {
      w.timer?.cancel();
    }
    _waiters.clear();
  }

  Future<void> _send(Uint8List b) async {
    if (_closed) throw _closedReason!;
    try {
      await transport.write(b);
    } catch (e) {
      if (_closed) throw _closedReason!;
      throw TransferException('Couldn\'t send to the logger: $e');
    }
  }

  /// Sends [cmd] and waits for the first reply matching [test].
  Future<LoggerEvent> _request(
      Uint8List cmd, bool Function(LoggerEvent) test, Duration timeout, String what) async {
    final w = _waitFor(test, timeout, what);
    try {
      await _send(cmd);
    } catch (_) {
      w.timer?.cancel();
      _waiters.remove(w);
      rethrow;
    }
    final e = await w.completer.future;
    if (e is ErrorEvent) _throwError(e);
    return e;
  }

  static Never _throwError(ErrorEvent e) =>
      throw TransferException(e.message, retryable: e.code == 4 || e.code == 6, loggerError: e.code);

  Future<HelloEvent> hello() async {
    final h = await _request(encodeHello(), (e) => e is HelloEvent || e is ErrorEvent,
        const Duration(seconds: 5), 'the logger to say hello') as HelloEvent;
    version = h.version;
    chunkSize = h.chunk;
    return h;
  }

  Future<List<FileEvent>> list() async {
    _listing = [];
    try {
      await _request(encodeList(), (e) => e is ListEndEvent || e is ErrorEvent,
          const Duration(seconds: 10), 'the file list');
      return List.of(_listing!);
    } finally {
      _listing = null;
    }
  }

  /// Downloads one file and checks its size and CRC-32.
  Future<ReceivedFile> get(String name, {void Function(int received, int total)? onProgress}) async {
    Timer? watchdog;
    try {
      final begin = _waitFor((e) => (e is BeginEvent && e.name == name) || e is ErrorEvent,
          const Duration(seconds: 10), 'the logger to start sending').completer.future;
      // Listen for END before asking, so a tiny file can't finish first.
      final end =
          _waitFor((e) => e is EndEvent || e is ErrorEvent, Duration.zero, 'END').completer.future;
      await _send(encodeGet(name));
      final b = await begin;
      if (b is ErrorEvent) _throwError(b);
      b as BeginEvent;
      _receiver = FileReceiver(name, b.size);
      _onProgress = onProgress;
      _lastDataAt = DateTime.now();
      onProgress?.call(0, b.size);

      final stalled = Completer<LoggerEvent>();
      watchdog = Timer.periodic(const Duration(seconds: 1), (_) {
        if (DateTime.now().difference(_lastDataAt) > stallTimeout && !stalled.isCompleted) {
          stalled.completeError(TransferException('The transfer stalled'));
        }
      });
      final e = await Future.any([end, stalled.future]);
      if (e is ErrorEvent) _throwError(e);
      return _receiver!.finish(e as EndEvent);
    } catch (e) {
      // Stop the logger sending, and drop the END waiter for this file.
      _dropWaiters();
      if (!_closed) {
        try {
          await transport.write(encodeAbort());
        } catch (_) {}
      }
      rethrow;
    } finally {
      watchdog?.cancel();
      _receiver = null;
      _onProgress = null;
    }
  }

  /// Tells the logger the file arrived intact, so it moves it to /uploaded.
  Future<void> confirm(String name, int crc) async {
    await _request(encodeConfirm(crc, name), (e) => (e is ConfirmedEvent && e.name == name) || e is ErrorEvent,
        const Duration(seconds: 30), 'the logger to confirm');
  }

  /// Reads the logger's trip meter (protocol v2).
  Future<MeterEvent> meter() async => await _request(encodeMeter(), (e) => e is MeterEvent || e is ErrorEvent,
      const Duration(seconds: 10), 'the trip meter') as MeterEvent;

  /// Tells the logger its trip meter counts from [reset] (protocol v2). It
  /// rebuilds the meter from its logs before answering, so allow a while.
  Future<MeterEvent> meterReset(DateTime reset) async => await _request(
      encodeMeterReset(reset.toUtc().millisecondsSinceEpoch ~/ 1000),
      (e) => e is MeterEvent || e is ErrorEvent,
      const Duration(seconds: 30),
      'the logger to reset its trip meter') as MeterEvent;

  /// Erases the logger's log files (protocol v3), then reads the meter it
  /// sends at zero. Deleting files on the card can take a while.
  Future<(ErasedEvent, MeterEvent)> eraseLogs() async {
    const wait = Duration(seconds: 60);
    // The METER comes straight after ERASED: listen for it before sending.
    final meterW = _waitFor((e) => e is MeterEvent, wait, 'the trip meter after erasing');
    final ErasedEvent erased;
    try {
      erased = await _request(encodeEraseLogs(), (e) => e is ErasedEvent || e is ErrorEvent, wait,
          'the logger to erase its files') as ErasedEvent;
    } catch (_) {
      meterW.timer?.cancel();
      _waiters.remove(meterW);
      rethrow;
    }
    final meter = await meterW.completer.future as MeterEvent;
    return (erased, meter);
  }

  void dispose() {
    _sub.cancel();
    _fail(TransferException('Closed', retryable: false));
  }
}
