import 'dart:io';

import 'package:catch_log/ble/protocol.dart';
import 'package:catch_log/core/crc32.dart';
import 'package:catch_log/data/database.dart';
import 'package:catch_log/data/repository.dart';
import 'package:catch_log/sync/logger_meter.dart';
import 'package:catch_log/sync/logger_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_logger.dart';

class _RecordingMeter extends LoggerMeter {
  _RecordingMeter({this.fail = false});
  final bool fail;
  final sent = <DateTime>[];
  @override
  bool supportedBy(HelloEvent hello) => true;
  @override
  Future<void> sendReset(LoggerSession session, DateTime resetUtc) async {
    if (fail) throw TransferException('the logger said no');
    sent.add(resetUtc);
  }
}

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

  group('trip meter', () {
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
      await repo.resetMeter(at: DateTime.utc(2026, 11, 9));
      final later = (await repo.trips()).where((t) => t.stats.startMs >= DateTime.utc(2026, 11, 9).millisecondsSinceEpoch);
      final m = await repo.meter();
      expect(m.trips, 2);
      expect(m.distanceM, closeTo(later.fold<double>(0, (a, t) => a + t.stats.distanceM), 0.001));
      expect(m.catches, later.fold<int>(0, (a, t) => a + t.stats.catchesByAngler.values.fold(0, (x, y) => x + y)));
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
      expect(m.onWater, greaterThan(const Duration(hours: 2, minutes: 30)));
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

  group('sending a queued reset at sync', () {
    late LoggerSession session;
    const hello = HelloEvent(1, 239);
    setUp(() => session = LoggerSession(FakeLogger({})));
    tearDown(() => session.dispose());

    test('nothing queued sends nothing', () async {
      final meter = _RecordingMeter();
      expect(await sendQueuedMeterReset(repo, meter, session, hello), MeterResetOutcome.nothingQueued);
      expect(meter.sent, isEmpty);
    });

    test('sends the reset time and clears the queue', () async {
      final at = await repo.resetMeter(at: DateTime.utc(2026, 11, 11, 5));
      final meter = _RecordingMeter();
      expect(await sendQueuedMeterReset(repo, meter, session, hello), MeterResetOutcome.sent);
      expect(meter.sent, [at]);
      expect(await repo.pendingMeterReset(), isNull);
    });

    test('a logger without meter commands leaves it queued', () async {
      await repo.resetMeter(at: DateTime.utc(2026, 11, 11, 5));
      expect(await sendQueuedMeterReset(repo, const NoLoggerMeter(), session, hello), MeterResetOutcome.unsupported);
      expect(await repo.pendingMeterReset(), isNotNull);
    });

    test('a refused reset stays queued and doesn\'t throw', () async {
      await repo.resetMeter(at: DateTime.utc(2026, 11, 11, 5));
      expect(await sendQueuedMeterReset(repo, _RecordingMeter(fail: true), session, hello), MeterResetOutcome.failed);
      expect(await repo.pendingMeterReset(), isNotNull);
    });
  });

  test('a version 1 database gains the settings table and keeps its data', () async {
    final path = '${tmp.path}/old.db';
    // A version 1 database as the first build created it (just enough of it).
    final old = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) => db.execute('CREATE TABLE files (id INTEGER PRIMARY KEY, name TEXT)'),
        ));
    await old.insert('files', {'id': 1, 'name': 'gps20261111.csv'});
    await old.close();

    final db = await openAppDatabase(factory: databaseFactoryFfi, path: path);
    final r = Repository(db, logDir: Directory('${tmp.path}/logs2'));
    expect(await db.getVersion(), schemaVersion);
    expect(await db.query('files'), hasLength(1));
    await r.resetMeter(at: DateTime.utc(2026, 11, 11));
    expect(await r.meterResetAt(), DateTime.utc(2026, 11, 11));
    await db.close();
  });
}
