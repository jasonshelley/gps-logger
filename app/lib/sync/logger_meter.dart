import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../ble/protocol.dart';
import '../core/meter.dart';
import '../data/repository.dart';
import 'logger_session.dart';

/// The logger's side of the trip meter (protocol v2, docs/ble-protocol.md,
/// "Trip meter"): reading the logger's own meter, and telling it about a
/// reset made on the phone so its screen shows the same meter.
abstract class LoggerMeter {
  const LoggerMeter();

  /// Whether this logger, going by its HELLO, understands the meter commands.
  bool supportedBy(HelloEvent hello);

  /// The logger's meter as it stands.
  Future<MeterEvent> read(LoggerSession session);

  /// Tells the logger to count from [resetUtc]. That time is the source of
  /// truth: the logger rebuilds its meter from its logs since then, so a reset
  /// queued while out of range gives the same result as an instant one.
  /// Returns the logger's meter after the reset; throws if it was refused.
  Future<MeterEvent> sendReset(LoggerSession session, DateTime resetUtc);
}

/// The meter commands over Bluetooth, for loggers on protocol version 2 or later.
class BleLoggerMeter extends LoggerMeter {
  const BleLoggerMeter();

  @override
  bool supportedBy(HelloEvent hello) => hello.version >= meterProtocolVersion;

  @override
  Future<MeterEvent> read(LoggerSession session) => session.meter();

  @override
  Future<MeterEvent> sendReset(LoggerSession session, DateTime resetUtc) async {
    final m = await session.meterReset(resetUtc);
    final want = resetUtc.millisecondsSinceEpoch ~/ 1000;
    if (m.resetUtcSeconds != want) {
      throw TransferException('The logger answered with reset ${m.resetUtcSeconds}, not $want');
    }
    return m;
  }
}

/// For loggers (and tests) without the meter commands.
class NoLoggerMeter extends LoggerMeter {
  const NoLoggerMeter();
  @override
  bool supportedBy(HelloEvent hello) => false;
  @override
  Future<MeterEvent> read(LoggerSession session) =>
      Future.error(UnsupportedError('This logger has no trip meter commands'));
  @override
  Future<MeterEvent> sendReset(LoggerSession session, DateTime resetUtc) =>
      Future.error(UnsupportedError('This logger has no trip meter commands'));
}

/// What the meter step of a sync did.
enum MeterSyncOutcome {
  /// The logger has no meter commands; any reset stays queued.
  unsupported,

  /// The logger already counted from the phone's reset time.
  inStep,

  /// A reset made on the phone was sent and accepted.
  sent,

  /// The logger counted from a different time than the phone, so the phone's
  /// reset was sent again (a swapped card, say).
  realigned,

  /// The phone had never been reset but the logger had, so the phone took the
  /// logger's reset time (after a reinstall, say).
  adopted,

  /// Sending or reading failed. A queued reset stays queued.
  failed,
}

class MeterSyncResult {
  const MeterSyncResult(this.outcome, this.logger, {this.error, this.queued = false});
  final MeterSyncOutcome outcome;

  /// A reset made on the phone is still waiting for the logger.
  final bool queued;

  /// The logger's meter after this step, when it could be read.
  final MeterEvent? logger;
  final String? error;
}

/// Brings the logger's trip meter in step with the phone's. Never throws: a
/// sync must not fail over the meter, and a reset that can't be sent stays
/// queued for next time.
Future<MeterSyncResult> syncLoggerMeter(
    Repository repo, LoggerMeter meter, LoggerSession session, HelloEvent hello) async {
  final pending = await repo.pendingMeterReset();
  if (!meter.supportedBy(hello)) {
    if (pending != null) debugPrint('[sync] meter reset of $pending stays queued: the logger has no meter commands');
    return MeterSyncResult(MeterSyncOutcome.unsupported, null, queued: pending != null);
  }
  try {
    if (pending != null) {
      final m = await meter.sendReset(session, pending);
      await repo.meterResetDelivered(pending);
      debugPrint('[sync] meter reset of $pending sent to the logger');
      return MeterSyncResult(MeterSyncOutcome.sent, m);
    }
    final m = await meter.read(session);
    final phone = await repo.meterResetAt();
    final phoneS = phone == null ? 0 : phone.millisecondsSinceEpoch ~/ 1000;
    if (m.resetUtcSeconds == phoneS) return MeterSyncResult(MeterSyncOutcome.inStep, m);
    if (phone == null) {
      await repo.adoptMeterReset(m.resetAt!);
      debugPrint('[sync] took the logger\'s meter reset ${m.resetAt}');
      return MeterSyncResult(MeterSyncOutcome.adopted, m);
    }
    final again = await meter.sendReset(session, phone);
    debugPrint('[sync] the logger counted from ${m.resetAt}; sent the phone\'s reset $phone again');
    return MeterSyncResult(MeterSyncOutcome.realigned, again);
  } catch (e) {
    debugPrint('[sync] trip meter: $e');
    return MeterSyncResult(MeterSyncOutcome.failed, null,
        error: e is TransferException ? e.message : '$e', queued: await repo.pendingMeterReset() != null);
  }
}

/// How the logger's meter compares with the phone's, after a sync.
class MeterComparison {
  MeterComparison(this.phone, this.logger);
  final MeterReading phone;
  final MeterEvent logger;

  int get phoneJase => phone.catchesByAngler['Jase'] ?? 0;
  int get phoneMatt => phone.catchesByAngler['Matt'] ?? 0;

  bool get catchesAgree => logger.jase == phoneJase && logger.matt == phoneMatt;

  /// The two count distance the same way, except that the phone skips GPS
  /// glitches (legs over 120 km/h), so allow a little.
  bool get distanceAgrees => (logger.distanceM - phone.distanceM).abs() <= math.max(50, phone.distanceM * 0.02);

  bool get timeAgrees => (logger.waterS - phone.onWater.inSeconds).abs() <= math.max(120, phone.onWater.inSeconds * 0.02);

  bool get agrees => catchesAgree && distanceAgrees && timeAgrees;
}
