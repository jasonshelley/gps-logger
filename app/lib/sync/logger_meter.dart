import 'package:flutter/foundation.dart';

import '../ble/protocol.dart';
import '../data/repository.dart';
import 'logger_session.dart';

/// The logger's side of the trip meter: the commands that tell the logger
/// about a reset made on the phone, so its screen shows the same meter.
///
/// The firmware is adding these commands and will document them in
/// docs/ble-protocol.md. Until then [NoLoggerMeter] is used: resets work on
/// the phone and stay queued for the logger.
abstract class LoggerMeter {
  const LoggerMeter();

  /// Whether this logger, going by its HELLO, understands the meter commands.
  bool supportedBy(HelloEvent hello);

  /// Tells the logger the meter was reset at [resetUtc]. That time is the
  /// source of truth: the logger counts from it, whatever its own clock says.
  /// Completes once the logger has accepted it; throws if it didn't.
  Future<void> sendReset(LoggerSession session, DateTime resetUtc);
}

/// For loggers (and app builds) without the meter commands yet.
class NoLoggerMeter extends LoggerMeter {
  const NoLoggerMeter();
  @override
  bool supportedBy(HelloEvent hello) => false;
  @override
  Future<void> sendReset(LoggerSession session, DateTime resetUtc) =>
      Future.error(UnsupportedError('This logger has no trip meter commands'));
}

/// What happened to a queued reset during a sync.
enum MeterResetOutcome { nothingQueued, sent, unsupported, failed }

/// Sends a reset queued on the phone, if there is one and the logger can take
/// it. Never throws: a reset that can't be sent stays queued for next time,
/// and the sync carries on.
Future<MeterResetOutcome> sendQueuedMeterReset(
    Repository repo, LoggerMeter meter, LoggerSession session, HelloEvent hello) async {
  final pending = await repo.pendingMeterReset();
  if (pending == null) return MeterResetOutcome.nothingQueued;
  if (!meter.supportedBy(hello)) {
    debugPrint('[sync] meter reset of $pending stays queued: the logger has no meter commands');
    return MeterResetOutcome.unsupported;
  }
  try {
    await meter.sendReset(session, pending);
    await repo.meterResetDelivered(pending);
    debugPrint('[sync] meter reset of $pending sent to the logger');
    return MeterResetOutcome.sent;
  } catch (e) {
    debugPrint('[sync] meter reset of $pending stays queued: $e');
    return MeterResetOutcome.failed;
  }
}
