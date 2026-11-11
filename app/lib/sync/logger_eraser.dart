import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import '../ble/ble_link.dart';
import '../ble/protocol.dart';
import 'logger_session.dart';
import 'permissions.dart';

/// The first protocol version with ERASE_LOGS.
const int eraseProtocolVersion = 3;

/// What the logger reported after erasing.
class LoggerEraseResult {
  const LoggerEraseResult({
    required this.deletedFiles,
    this.failedFiles = 0,
    this.resetNotSaved = false,
    required this.meter,
  });

  /// How many log files the logger deleted.
  final int deletedFiles;

  /// Log files it couldn't delete. They're still on the card.
  final int failedFiles;

  /// The logger couldn't save its new reset time to the card, so after a
  /// restart it would count from the old one.
  final bool resetNotSaved;

  /// The logger's trip meter afterwards: zero, counting from its new reset.
  final MeterEvent meter;
}

/// Erasing the logger's log files (ERASE_LOGS, protocol v3, in
/// docs/ble-protocol.md). Only ever used on a live connection, after the
/// person has seen the files and confirmed: an erase is never queued for a
/// later sync, because it could delete trips logged in the meantime.
abstract class LoggerEraser {
  const LoggerEraser();

  /// Whether this logger, going by its HELLO, can erase its files.
  bool supportedBy(HelloEvent hello);

  /// Erases every log file on the logger's card. Throws if it was refused.
  Future<LoggerEraseResult> erase(LoggerSession session);
}

/// ERASE_LOGS over Bluetooth, for loggers on protocol version 3 or later.
class BleLoggerEraser extends LoggerEraser {
  const BleLoggerEraser();

  @override
  bool supportedBy(HelloEvent hello) => hello.version >= eraseProtocolVersion;

  @override
  Future<LoggerEraseResult> erase(LoggerSession session) async {
    try {
      final (erased, meter) = await session.eraseLogs();
      return LoggerEraseResult(
        deletedFiles: erased.deleted,
        failedFiles: erased.failed,
        resetNotSaved: erased.resetNotSaved,
        meter: meter,
      );
    } on TransferException catch (e) {
      // Busy (4), no card (5), short (9) or bad guard bytes (10): the logger
      // erased nothing.
      if (const {4, 5, 9, 10}.contains(e.loggerError)) {
        throw TransferException('${e.message}. Nothing was erased.', loggerError: e.loggerError);
      }
      rethrow;
    }
  }
}

enum EraseLoggerPhase {
  /// Permission, Bluetooth, scanning, connecting, HELLO and LIST.
  connecting,

  /// The logger's firmware has no erase command.
  needsFirmware,

  /// Connected and listed: waiting for the person to confirm.
  confirm,
  erasing,
  done,
  failed,
}

/// A connected logger: the session and its HELLO.
typedef LoggerConnection = ({LoggerSession session, HelloEvent hello, Future<void> Function() close});

/// Connects to the logger over Bluetooth: the same steps as a sync, but it
/// fails with a message rather than walking through permission screens.
Future<LoggerConnection> connectToLogger() async {
  if (!await BlePermissions.granted()) {
    throw TransferException('Catch Log needs the Nearby devices permission. Sync once to allow it, then try again.');
  }
  final state = await UniversalBle.getBluetoothAvailabilityState();
  if (state != AvailabilityState.poweredOn) {
    throw TransferException('Bluetooth is off. Turn it on, then try again.');
  }
  final device = await LoggerScanner.findLogger();
  if (device == null) {
    throw TransferException('No logger found. Put its switch on Transfer, keep it close, and try again.');
  }
  final transport = await BleLoggerTransport.connect(device.deviceId);
  final session = LoggerSession(transport);
  try {
    final hello = await session.hello();
    return (
      session: session,
      hello: hello,
      close: () async {
        session.dispose();
        await transport.close();
      }
    );
  } catch (_) {
    session.dispose();
    await transport.close();
    rethrow;
  }
}

/// Erases the logger's files: connects, lists the files still waiting to be
/// synced so the person can see what would be lost, waits for confirmation,
/// then erases, all on one connection.
class EraseLoggerController extends ChangeNotifier {
  EraseLoggerController({this.eraser = const BleLoggerEraser(), this.connect = connectToLogger, this.onMeterReset});

  final LoggerEraser eraser;
  final Future<LoggerConnection> Function() connect;

  /// Told the logger's new meter reset (null if it had no GPS time), so the
  /// phone's trip meter counts from the same moment. Returns the phone's
  /// reset time.
  final Future<DateTime> Function(DateTime? loggerReset)? onMeterReset;

  /// The phone's trip meter reset after the erase.
  DateTime? phoneResetAt;

  /// Files still on the logger after an erase that couldn't delete them all.
  List<FileEvent> remaining = [];

  EraseLoggerPhase phase = EraseLoggerPhase.connecting;
  String? error;

  /// The logger's protocol version, once connected.
  int? version;

  /// Files on the logger not yet synced to a phone (LIST only reports these).
  List<FileEvent> unsynced = [];
  LoggerEraseResult? result;

  LoggerConnection? _link;
  bool _disposed = false;

  void _set(EraseLoggerPhase p, {String? err}) {
    if (_disposed) return;
    debugPrint('[erase] ${p.name}${err != null ? ': $err' : ''}');
    phase = p;
    error = err;
    notifyListeners();
  }

  Future<void> start() async {
    await _close();
    result = null;
    unsynced = [];
    remaining = [];
    phoneResetAt = null;
    _set(EraseLoggerPhase.connecting);
    try {
      final link = await connect();
      if (_disposed) {
        await link.close();
        return;
      }
      _link = link;
      version = link.hello.version;
      if (!eraser.supportedBy(link.hello)) {
        await _close();
        _set(EraseLoggerPhase.needsFirmware);
        return;
      }
      unsynced = (await link.session.list())..sort((a, b) => a.name.compareTo(b.name));
      debugPrint('[erase] logger v$version, ${unsynced.length} unsynced files: '
          '${unsynced.map((f) => '${f.name} ${f.size}').join(', ')}');
      _set(EraseLoggerPhase.confirm);
    } catch (e) {
      await _close();
      _set(EraseLoggerPhase.failed, err: _friendly(e));
    }
  }

  /// Sends the erase. Only valid after the person confirmed the listed files.
  Future<void> erase() async {
    final link = _link;
    if (phase != EraseLoggerPhase.confirm || link == null) return;
    _set(EraseLoggerPhase.erasing);
    try {
      final r = result = await eraser.erase(link.session);
      debugPrint('[erase] the logger deleted ${r.deletedFiles} files, ${r.failedFiles} failed, '
          'flags ${r.resetNotSaved ? 1 : 0}; meter reset ${r.meter.resetUtcSeconds}');
      if (r.failedFiles > 0) {
        try {
          remaining = (await link.session.list())..sort((a, b) => a.name.compareTo(b.name));
        } catch (e) {
          debugPrint('[erase] couldn\'t list what was left: $e');
        }
      }
      final adopt = onMeterReset;
      if (adopt != null) {
        phoneResetAt = await adopt(r.meter.resetAt);
        debugPrint('[erase] phone trip meter now counts from $phoneResetAt');
      }
      _set(EraseLoggerPhase.done);
    } catch (e) {
      _set(EraseLoggerPhase.failed, err: _friendly(e));
    } finally {
      await _close();
    }
  }

  Future<void> _close() async {
    final l = _link;
    _link = null;
    await l?.close();
  }

  String _friendly(Object e) {
    if (e is TransferException) return e.message;
    final s = e.toString();
    if (s.contains('Timeout') || s.contains('timed out')) return 'The logger took too long to answer. Try again.';
    return 'Couldn\'t reach the logger: $s';
  }

  @override
  void dispose() {
    _disposed = true;
    _close();
    super.dispose();
  }
}
