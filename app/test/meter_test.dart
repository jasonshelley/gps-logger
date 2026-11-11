import 'dart:io';
import 'dart:typed_data';

import 'package:catch_log/ble/protocol.dart';
import 'package:catch_log/core/crc32.dart';
import 'package:catch_log/core/log_csv.dart';
import 'package:catch_log/core/meter.dart';
import 'package:catch_log/core/trips.dart';
import 'package:catch_log/data/database.dart';
import 'package:catch_log/data/repository.dart';
import 'package:catch_log/sync/logger_meter.dart';
import 'package:catch_log/sync/logger_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_logger.dart';

DateTime _utcS(int s) => DateTime.fromMillisecondsSinceEpoch(s * 1000, isUtc: true);

void main() {
  sqfliteFfiInit();
  late Repository repo;
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('catchlog');
    final db = await openAppDatabase(factory: databaseFactoryFfi, path: '${tmp.path}/catch_log.db');
    repo = Repository(db, logDir: Directory('${tmp.path}/logs'));
  });
  tearDown(() async {
    await repo.db.close();
    await tmp.delete(recursive: true);
  });

  Future<void> import(String name) {
    final bytes = File('test/fixtures/$name').readAsBytesSync();
    return repo.importLog(name, bytes, Crc32.of(bytes));
  }

  group('trip meter on the phone', () {
    test('never reset: counts every trip, like the totals', () async {
      await import('gps20261108.csv');
      await import('gps20261110.csv');
      final m = await repo.meter();
      final all = await repo.totals();
      expect(await repo.meterResetAt(), isNull);
      expect(m.trips, 3);
      expect(m.distanceM, closeTo(all.distanceM, 0.001));
      expect(m.onWater, all.onWater);
      expect(m.catchesByAngler, all.catchesByAngler);
    });

    test('time on the water follows the logger\'s rule, not the trip span', () async {
      await import('gps20261108.csv');
      final trip = (await repo.trips()).single;
      final m = await repo.meter();
      // The fixture has a 20-minute gap with the logger off: that gap is in
      // the trip's span but isn't time on the water.
      expect(m.onWater, lessThanOrEqualTo(trip.stats.duration - const Duration(minutes: 20)));
      expect(m.onWater, greaterThan(trip.stats.duration - const Duration(minutes: 25)));
    });

    test('reset after everything reads zero', () async {
      await import('gps20261108.csv');
      await repo.resetMeter(at: DateTime.utc(2026, 11, 20));
      final m = await repo.meter();
      expect(m.trips, 0);
      expect(m.catches, 0);
      expect(m.distanceM, 0);
      expect(m.onWater, Duration.zero);
    });

    test('reset between trips counts only the later ones', () async {
      await import('gps20261108.csv');
      await import('gps20261110.csv');
      final cut = DateTime.utc(2026, 11, 9);
      await repo.resetMeter(at: cut);
      final later = (await repo.trips()).where((t) => t.stats.startMs >= cut.millisecondsSinceEpoch);
      final m = await repo.meter();
      expect(m.trips, 2);
      expect(m.distanceM, closeTo(later.fold<double>(0, (a, t) => a + t.stats.distanceM), 0.001));
      expect(m.catches, later.fold<int>(0, (a, t) => a + t.stats.totalCatches));
    });

    test('reset during a trip counts that trip from the reset on', () async {
      await import('gps20261108.csv');
      final trip = (await repo.trips()).single;
      // Catches after 20:00 UTC: Jase 20:09, 21:38, 21:53; Matt 21:03, 22:24.
      await repo.resetMeter(at: DateTime.utc(2026, 11, 7, 20));
      final m = await repo.meter();
      expect(m.trips, 1);
      expect(m.catchesByAngler, {'Jase': 3, 'Matt': 2});
      expect(m.distanceM, greaterThan(0));
      expect(m.distanceM, lessThan(trip.stats.distanceM));
      // The trip ends at 22:38, so at most 2 h 38 m since the reset.
      expect(m.onWater, lessThanOrEqualTo(const Duration(hours: 2, minutes: 38)));
      expect(m.onWater, greaterThan(const Duration(hours: 2)));
    });

    test('totals include catches with no time; the meter can\'t place them', () async {
      await import('gps20261108.csv');
      await import('gpsnodate.csv');
      final all = await repo.totals();
      final m = await repo.meter();
      expect(all.catches, 9);
      expect(m.catches, 7);
    });

    test('a reset is rounded to the second and queued for the logger', () async {
      var notified = 0;
      repo.addListener(() => notified++);
      final at = await repo.resetMeter(at: DateTime.utc(2026, 11, 11, 5, 6, 7, 890));
      expect(at, DateTime.utc(2026, 11, 11, 5, 6, 7));
      expect(await repo.meterResetAt(), at);
      expect(await repo.pendingMeterReset(), at);
      expect(notified, 1);
    });

    test('delivering an older reset keeps a newer one queued', () async {
      final first = await repo.resetMeter(at: DateTime.utc(2026, 11, 11, 5));
      final second = await repo.resetMeter(at: DateTime.utc(2026, 11, 11, 6));
      await repo.meterResetDelivered(first);
      expect(await repo.pendingMeterReset(), second);
      await repo.meterResetDelivered(second);
      expect(await repo.pendingMeterReset(), isNull);
      expect(await repo.meterResetAt(), second);
    });
  });

  group('logged time', () {
    TrackPoint pt(int s, double lat) =>
        TrackPoint(time: DateTime.utc(2026, 11, 11).add(Duration(seconds: s)), lat: lat, lon: 151.2);

    test('counts gaps of up to 15 minutes, not longer ones', () {
      const g = 15 * 60;
      final s = computeTripStats(
          [pt(0, -33.8), pt(60, -33.8001), pt(60 + g, -33.8002), pt(60 + g + g + 1, -33.8003)], []);
      expect(s.loggedS, 60 + g);
    });

    test('counts the time across a GPS glitch even though its distance is skipped', () {
      final s = computeTripStats([pt(0, -33.8), pt(10, -33.0)], []); // about 89 km in 10 s
      expect(s.distanceM, 0);
      expect(s.loggedS, 10);
    });
  });

  group('protocol v2 codec', () {
    test('decodes the METER example from docs/ble-protocol.md', () {
      final b = Uint8List.fromList([
        0x87, 0x80, 0x20, 0xf4, 0x6a, 0x03, 0x00, 0x01, 0x00, 0x39, 0x30, 0x00, 0x00, 0x0c, 0x30, 0x00, 0x00, 0x00, //
      ]);
      final m = decodeEvent(b) as MeterEvent;
      expect(m.resetUtcSeconds, 1794384000);
      expect(m.resetAt, DateTime.utc(2026, 11, 11, 8));
      expect(m.jase, 3);
      expect(m.matt, 1);
      expect(m.distanceM, 12345);
      expect(m.waterS, 12300);
      expect(m.incomplete, isFalse);
      expect(m.clockNotSet, isFalse);
    });

    test('decodes the flags and a never-reset meter', () {
      final b = Uint8List(18)..[0] = 0x87;
      b[17] = 0x03;
      final m = decodeEvent(b) as MeterEvent;
      expect(m.resetAt, isNull);
      expect(m.incomplete, isTrue);
      expect(m.clockNotSet, isTrue);
    });

    test('a short METER is a protocol error', () {
      expect(() => decodeEvent(Uint8List.fromList([0x87, 1, 2])), throwsA(isA<ProtocolException>()));
    });

    test('encodes METER and METER_RESET', () {
      expect(encodeMeter(), [0x06]);
      expect(encodeMeterReset(1794384000), [0x07, 0x80, 0x20, 0xf4, 0x6a]);
    });
  });

  group('the meter step of a sync, against a fake logger', () {
    late FakeLogger logger;
    late LoggerSession session;
    late HelloEvent hello;
    const ble = BleLoggerMeter();

    Future<void> connect({int version = protocolVersion}) async {
      logger = FakeLogger({}, version: version);
      session = LoggerSession(logger);
      hello = await session.hello();
    }

    tearDown(() => session.dispose());

    test('a version 1 logger: no meter commands, the reset stays queued', () async {
      await connect(version: 1);
      await repo.resetMeter(at: DateTime.utc(2026, 11, 11, 5));
      final r = await syncLoggerMeter(repo, ble, session, hello);
      expect(r.outcome, MeterSyncOutcome.unsupported);
      expect(r.queued, isTrue);
      expect(logger.sent, isNot(contains(Cmd.meterReset)));
      expect(await repo.pendingMeterReset(), isNotNull);
      // And a version 1 logger really does refuse METER.
      await expectLater(session.meter(), throwsA(isA<TransferException>()));
    });

    test('a queued reset is sent, accepted and cleared', () async {
      await connect();
      logger.meterReset = 1794200000;
      final at = await repo.resetMeter(at: DateTime.utc(2026, 11, 11, 8));
      final r = await syncLoggerMeter(repo, ble, session, hello);
      expect(r.outcome, MeterSyncOutcome.sent);
      expect(logger.meterReset, 1794384000);
      expect(r.logger!.resetAt, at);
      expect(await repo.pendingMeterReset(), isNull);
    });

    test('in step: reads the meter and sends nothing', () async {
      await connect();
      await repo.resetMeter(at: _utcS(1794384000));
      await repo.meterResetDelivered(_utcS(1794384000));
      logger
        ..meterReset = 1794384000
        ..jase = 3
        ..matt = 1;
      final r = await syncLoggerMeter(repo, ble, session, hello);
      expect(r.outcome, MeterSyncOutcome.inStep);
      expect(r.logger!.jase, 3);
      expect(logger.sent, isNot(contains(Cmd.meterReset)));
    });

    test('never reset on either side counts as in step', () async {
      await connect();
      final r = await syncLoggerMeter(repo, ble, session, hello);
      expect(r.outcome, MeterSyncOutcome.inStep);
    });

    test('a logger counting from another time is put back in step with the phone', () async {
      await connect();
      await repo.resetMeter(at: _utcS(1794384000));
      await repo.meterResetDelivered(_utcS(1794384000));
      logger.meterReset = 0; // a fresh card, say
      final r = await syncLoggerMeter(repo, ble, session, hello);
      expect(r.outcome, MeterSyncOutcome.realigned);
      expect(logger.meterReset, 1794384000);
    });

    test('a phone that was never reset takes the logger\'s reset time', () async {
      await connect();
      logger.meterReset = 1794384000;
      final r = await syncLoggerMeter(repo, ble, session, hello);
      expect(r.outcome, MeterSyncOutcome.adopted);
      expect(await repo.meterResetAt(), DateTime.utc(2026, 11, 11, 8));
      expect(await repo.pendingMeterReset(), isNull);
      expect(logger.sent, isNot(contains(Cmd.meterReset)));
    });

    test('a card that can\'t be written (ERROR 5) keeps the reset queued, without throwing', () async {
      await connect();
      logger.meterResetError = 5;
      await repo.resetMeter(at: DateTime.utc(2026, 11, 11, 8));
      final r = await syncLoggerMeter(repo, ble, session, hello);
      expect(r.outcome, MeterSyncOutcome.failed);
      expect(r.queued, isTrue);
      expect(r.error, contains('SD card'));
      expect(await repo.pendingMeterReset(), isNotNull);
    });

    test('a reply with a different reset time is not taken as accepted', () async {
      await connect();
      logger.meterResetAnswer = 1;
      await repo.resetMeter(at: DateTime.utc(2026, 11, 11, 8));
      final r = await syncLoggerMeter(repo, ble, session, hello);
      expect(r.outcome, MeterSyncOutcome.failed);
      expect(await repo.pendingMeterReset(), isNotNull);
    });

    test('NoLoggerMeter never sends anything', () async {
      await connect();
      await repo.resetMeter(at: DateTime.utc(2026, 11, 11, 8));
      final r = await syncLoggerMeter(repo, const NoLoggerMeter(), session, hello);
      expect(r.outcome, MeterSyncOutcome.unsupported);
      expect(logger.sent, [Cmd.hello]);
    });
  });

  group('comparing the meters', () {
    MeterEvent logger({int jase = 3, int matt = 1, int distanceM = 12345, int waterS = 12300}) => MeterEvent(
        resetUtcSeconds: 0, jase: jase, matt: matt, distanceM: distanceM, waterS: waterS, flags: 0);
    const phone = MeterReading(
      catchesByAngler: {'Jase': 3, 'Matt': 1},
      distanceM: 12300,
      onWater: Duration(seconds: 12250),
      trips: 1,
    );

    test('small differences in distance and time still agree', () {
      expect(MeterComparison(phone, logger()).agrees, isTrue);
    });

    test('a different catch count disagrees', () {
      final c = MeterComparison(phone, logger(matt: 2));
      expect(c.catchesAgree, isFalse);
      expect(c.agrees, isFalse);
    });

    test('a big difference in time disagrees', () {
      expect(MeterComparison(phone, logger(waterS: 20000)).timeAgrees, isFalse);
    });
  });

  test('a version 1 database is upgraded: settings added, trips given their logged time', () async {
    await import('gps20261108.csv');
    final before = (await repo.trips()).single.stats.loggedS;
    expect(before, greaterThan(0));
    // Turn it back into a version 1 database.
    await repo.db.execute('DROP TABLE settings');
    await repo.db.execute('ALTER TABLE trips DROP COLUMN logged_s');
    await repo.db.setVersion(1);
    await repo.db.close();

    final db = await openAppDatabase(factory: databaseFactoryFfi, path: '${tmp.path}/catch_log.db');
    repo = Repository(db, logDir: Directory('${tmp.path}/logs'));
    expect(await db.getVersion(), schemaVersion);
    expect((await repo.trips()).single.stats.loggedS, 0); // not filled in yet
    var notified = 0;
    repo.addListener(() => notified++);
    await repo.upgradeTrips();
    expect((await repo.trips()).single.stats.loggedS, before);
    expect(notified, 1);
    await repo.upgradeTrips(); // nothing left to do
    expect(notified, 1);
    await repo.resetMeter(at: DateTime.utc(2026, 11, 11));
    expect(await repo.meterResetAt(), DateTime.utc(2026, 11, 11));
  });
}
