import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:catch_log/ble/protocol.dart';
import 'package:catch_log/core/crc32.dart';
import 'package:catch_log/sync/logger_session.dart';

/// A pretend logger implementing docs/ble-protocol.md, for tests.
class FakeLogger implements LoggerTransport {
  FakeLogger(Map<String, List<int>> files, {this.chunk = 239, this.version = protocolVersion})
      : files = {for (final e in files.entries) e.key: Uint8List.fromList(e.value)};

  final Map<String, Uint8List> files;
  final Map<String, Uint8List> uploaded = {};
  final int chunk;

  /// The protocol version it reports in HELLO. Version 1 has no trip meter.
  final int version;

  /// The trip meter (v2). [meterReset] is UTC seconds, 0 = never reset.
  int meterReset = 0;
  int jase = 0, matt = 0, distanceM = 0, waterS = 0, meterFlags = 0;

  /// Answer METER_RESET with this error code instead (5 = card not writable).
  int? meterResetError;

  /// Answer METER_RESET with this reset time instead of the one sent.
  int? meterResetAnswer;

  /// ERASE_LOGS (v3): files that refuse to be deleted, an error code to
  /// answer with instead (4 busy, 5 no card), and the logger's clock (UTC
  /// seconds, 0 = no GPS time) that becomes the meter's reset.
  Set<String> undeletable = {};
  int? eraseError;
  int clockUtc = 1794384000;
  int erasedFlags = 0;

  /// Fault injection.
  int? dropChunkAt; // skip the DATA message at this offset
  int? corruptByteAt; // flip a byte in the data sent (CRC in END stays right)
  int? disconnectAfterBytes;
  bool silentAfterBegin = false;

  final _tx = StreamController<Uint8List>.broadcast();
  final _disconnected = Completer<void>();
  final sent = <int>[]; // opcodes received, for assertions

  @override
  Stream<Uint8List> get notifications => _tx.stream;

  @override
  Future<void> get disconnected => _disconnected.future;

  void disconnect() {
    if (!_disconnected.isCompleted) _disconnected.complete();
  }

  void _emit(List<int> b) => scheduleMicrotask(() => _tx.add(Uint8List.fromList(b)));

  Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);
  void _emitMeter() => _emit([
        Evt.meter,
        ..._u32(meterReset),
        ..._u16(jase),
        ..._u16(matt),
        ..._u32(distanceM),
        ..._u32(waterS),
        meterFlags,
      ]);

  Uint8List _u16(int v) => Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little);

  @override
  Future<void> write(Uint8List data) async {
    if (_disconnected.isCompleted) throw StateError('not connected');
    final op = data[0];
    sent.add(op);
    final name = op == Cmd.get || op == Cmd.confirm ? ascii.decode(data.sublist(op == Cmd.confirm ? 5 : 1)) : '';
    if (version < meterProtocolVersion && (op == Cmd.meter || op == Cmd.meterReset) ||
        version < 3 && op == Cmd.eraseLogs) {
      _emit([Evt.error, 1, ...ascii.encode('unknown command')]);
      return;
    }
    switch (op) {
      case Cmd.hello:
        _emit([Evt.hello, version, ..._u16(chunk)]);
      case Cmd.meter:
        _emitMeter();
      case Cmd.meterReset:
        if (data.length < 5) {
          _emit([Evt.error, 9, ...ascii.encode('short')]);
        } else if (meterResetError != null) {
          _emit([Evt.error, meterResetError!, ...ascii.encode('no')]);
        } else {
          meterReset = meterResetAnswer ?? ByteData.sublistView(data).getUint32(1, Endian.little);
          _emitMeter();
        }
      case Cmd.list:
        final names = files.keys.toList()..sort();
        for (final n in names) {
          _emit([Evt.file, ..._u32(files[n]!.length), ...ascii.encode(n)]);
        }
        _emit([Evt.listEnd, ..._u16(names.length)]);
      case Cmd.get:
        final f = files[name];
        if (f == null) {
          _emit([Evt.error, 3, ...ascii.encode('not found')]);
          return;
        }
        _emit([Evt.begin, ..._u32(f.length), ...ascii.encode(name)]);
        if (silentAfterBegin) return;
        for (var off = 0; off < f.length; off += chunk) {
          if (disconnectAfterBytes != null && off >= disconnectAfterBytes!) {
            scheduleMicrotask(disconnect);
            return;
          }
          if (off == dropChunkAt) continue;
          final end = off + chunk > f.length ? f.length : off + chunk;
          final payload = Uint8List.fromList(f.sublist(off, end));
          if (corruptByteAt != null && corruptByteAt! >= off && corruptByteAt! < end) {
            payload[corruptByteAt! - off] ^= 0xFF;
          }
          _emit([Evt.data, ..._u32(off), ...payload]);
        }
        _emit([Evt.end, ..._u32(f.length), ..._u32(Crc32.of(f))]);
      case Cmd.confirm:
        final crc = ByteData.sublistView(data).getUint32(1, Endian.little);
        final f = files[name];
        if (f == null) {
          _emit([Evt.error, 3, ...ascii.encode('not found')]);
        } else if (Crc32.of(f) != crc) {
          _emit([Evt.error, 7, ...ascii.encode('crc mismatch')]);
        } else {
          uploaded[name] = files.remove(name)!;
          _emit([Evt.confirmed, ...ascii.encode(name)]);
        }
      case Cmd.eraseLogs:
        if (data.length < 5) {
          _emit([Evt.error, 9, ...ascii.encode('short')]);
        } else if (ascii.decode(data.sublist(1, 5), allowInvalid: true) != 'ERAS') {
          _emit([Evt.error, 10, ...ascii.encode('bad magic')]);
        } else if (eraseError != null) {
          _emit([Evt.error, eraseError!, ...ascii.encode('no')]);
        } else {
          var deleted = 0, failed = 0;
          for (final folder in [files, uploaded]) {
            for (final n in folder.keys.toList()) {
              if (undeletable.contains(n)) {
                failed++;
              } else {
                folder.remove(n);
                deleted++;
              }
            }
          }
          meterReset = clockUtc;
          jase = matt = distanceM = waterS = 0;
          meterFlags = clockUtc == 0 ? 2 : 0;
          _emit([Evt.erased, ..._u16(deleted), ..._u16(failed), erasedFlags]);
          _emitMeter();
        }
      case Cmd.abort:
        break;
      default:
        _emit([Evt.error, 1, ...ascii.encode('unknown')]);
    }
  }
}
