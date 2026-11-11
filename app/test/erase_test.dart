import 'dart:io';

import 'package:catch_log/ble/protocol.dart';
import 'package:catch_log/core/crc32.dart';
import 'package:catch_log/data/database.dart';
import 'package:catch_log/data/repository.dart';
import 'package:catch_log/sync/logger_eraser.dart';
import 'package:catch_log/sync/logger_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_logger.dart';

/// A pretend ERASE_LOGS, until the protocol v3 bytes are specified.
class _FakeEraser extends LoggerEraser {
  _FakeEraser({this.fail});
  final String? fail;
  int calls = 0;

  @override
  bool supportedBy(HelloEvent hello) => hello.version >= eraseProtocolVersion;

  @override
  Future<LoggerEraseResult> erase(LoggerSession session) async {
    calls++;
    if (fail != null) throw TransferException(fail!);
    return const LoggerEraseResult(deletedFiles: 7);
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

  Future<void> import(String name, {bool sample = false}) {
    final bytes = File('test/fixtures/$name').readAsBytesSync();
    // As loadSampleTrips does it: named sample-..., moved back 52 weeks.
    return sample
        ? repo.importLog('${Repository.samplePrefix}$name', bytes, Crc32.of(bytes), shift: const Duration(days: -364))
        : repo.importLog(name, bytes, Crc32.of(bytes));
  }

  Future<int> count(String table) async => (await repo.db.rawQuery('SELECT COUNT(*) AS n FROM $table')).first['n'] as int;

  Future<void> cacheConditionsForEveryTrip() async {
    for (final t in await repo.trips()) {
      await repo.saveConditions(t.id, -33.8, 151.2, '{}', '{}');
    }
  }

  group('remove sample trips', () {
    test('deletes the samples and leaves real trips, the meter and settings alone', () async {
      await import('real_gps20261111.csv');
      await import('gpsnodate.csv'); // real catches with no date
      await import('gps20261108.csv', sample: true);
      await import('gps20261110.csv', sample: true);
      final real = (await repo.trips()).where((t) => t.stats.start.year == 2026).toList();
      expect(real, hasLength(1));
      expect(await repo.trips(), hasLength(4)); // one real, three sample
      await cacheConditionsForEveryTrip();
      final reset = await repo.resetMeter(at: DateTime.utc(2026, 11, 11, 3));
      await repo.db.insert('settings', {'key': 'some_preference', 'value': 'kept'});
      final logsBefore = repo.logDir.listSync().length;

      await repo.removeSamples();

      expect(await repo.hasSamples(), isFalse);
      final left = await repo.trips();
      expect(left.map((t) => t.id), real.map((t) => t.id));
      expect(left.single.stats.distanceM, real.single.stats.distanceM);
      expect(await repo.undatedCatches(), hasLength(2));
      expect(await count('files'), 2);
      expect(await count('trip_conditions'), 1); // only the real trip's
      expect(await repo.cachedConditions(real.single.id), isNotNull);
      expect(repo.logDir.listSync(), hasLength(logsBefore - 2));
      expect(await repo.meterResetAt(), reset);
      expect(await repo.pendingMeterReset(), reset);
      expect((await repo.db.query('settings', where: "key = 'some_preference'")).single['value'], 'kept');
    });
  });

  group('erase all data', () {
    test('empties every table and the log folder, keeping other settings', () async {
      await import('real_gps20261111.csv');
      await import('gpsnodate.csv');
      await import('gps20261108.csv', sample: true);
      await cacheConditionsForEveryTrip();
      await repo.resetMeter(at: DateTime.utc(2026, 11, 11, 3)); // also queued for the logger
      await repo.db.insert('settings', {'key': 'some_preference', 'value': 'kept'});
      expect(repo.logDir.listSync(), isNotEmpty);
      var notified = 0;
      repo.addListener(() => notified++);

      await repo.eraseAll();

      expect(notified, 1);
      for (final t in ['files', 'points', 'catches', 'trips', 'trip_conditions']) {
        expect(await count(t), 0, reason: t);
      }
      expect(repo.logDir.existsSync(), isFalse);
      expect(await repo.trips(), isEmpty);
      expect(await repo.undatedCatches(), isEmpty);
      expect(await repo.hasSamples(), isFalse);
      expect(await repo.fileCount(), 0);
      expect(await repo.lastSync(), isNull);
      // The trip meter is back to its first-run state, with nothing queued.
      expect(await repo.meterResetAt(), isNull);
      expect(await repo.pendingMeterReset(), isNull);
      final m = await repo.meter(), all = await repo.totals();
      for (final r in [m, all]) {
        expect((r.trips, r.catches, r.distanceM, r.onWater), (0, 0, 0.0, Duration.zero));
      }
      expect((await repo.db.query('settings')).map((r) => r['key']), ['some_preference']);
    });

    test('the app works as on first run afterwards: samples and real files import again', () async {
      await import('gps20261108.csv');
      await repo.eraseAll();
      await import('gps20261108.csv', sample: true); // "Try it with sample trips"
      expect(await repo.hasSamples(), isTrue);
      await import('gps20261108.csv'); // the same file again counts as new
      expect(await repo.trips(), hasLength(2));
      expect(repo.logDir.listSync(), hasLength(2));
    });

    test('erasing an empty phone is harmless', () async {
      await repo.eraseAll();
      expect(await repo.trips(), isEmpty);
    });
  });

  group('erase the logger', () {
    late FakeLogger logger;
    var closed = 0;

    Future<LoggerConnection> Function() connectTo(FakeLogger l) => () async {
          logger = l;
          final s = LoggerSession(l);
          final hello = await s.hello();
          return (session: s, hello: hello, close: () async => closed++);
        };

    setUp(() => closed = 0);

    test('a version 2 logger is told to update its firmware, and nothing is sent', () async {
      final eraser = _FakeEraser();
      final c = EraseLoggerController(eraser: eraser, connect: connectTo(FakeLogger({'gps20261111.csv': [1, 2]})));
      await c.start();
      expect(c.phase, EraseLoggerPhase.needsFirmware);
      expect(c.version, 2);
      expect(eraser.calls, 0);
      expect(logger.sent, [Cmd.hello]); // not even LIST
      expect(closed, 1);
    });

    test('lists the unsynced files, and erases only after confirming', () async {
      final eraser = _FakeEraser();
      final c = EraseLoggerController(
          eraser: eraser,
          connect: connectTo(FakeLogger({'gps20261111.csv': List.filled(300, 65), 'gpsnodate.csv': [65]}, version: 3)));
      await c.start();
      expect(c.phase, EraseLoggerPhase.confirm);
      expect(c.unsynced.map((f) => (f.name, f.size)), [('gps20261111.csv', 300), ('gpsnodate.csv', 1)]);
      expect(eraser.calls, 0); // waiting for the person
      expect(closed, 0); // the connection stays up until then

      await c.erase();
      expect(c.phase, EraseLoggerPhase.done);
      expect(c.result!.deletedFiles, 7);
      expect(eraser.calls, 1);
      expect(closed, 1);
      await c.erase(); // a second tap does nothing
      expect(eraser.calls, 1);
    });

    test('a refused erase is reported and can be tried again', () async {
      final eraser = _FakeEraser(fail: 'The logger can\'t read or write its SD card');
      final c = EraseLoggerController(eraser: eraser, connect: connectTo(FakeLogger({}, version: 3)));
      await c.start();
      expect(c.unsynced, isEmpty);
      await c.erase();
      expect(c.phase, EraseLoggerPhase.failed);
      expect(c.error, contains('SD card'));
      expect(closed, 1);
      await c.start();
      expect(c.phase, EraseLoggerPhase.confirm);
    });

    test('no logger in reach fails with the reason', () async {
      final c = EraseLoggerController(
          eraser: _FakeEraser(), connect: () async => throw TransferException('No logger found. Put its switch on Transfer'));
      await c.start();
      expect(c.phase, EraseLoggerPhase.failed);
      expect(c.error, startsWith('No logger found'));
    });

    test('the real eraser sends nothing until the v3 message is specified', () async {
      const ble = BleLoggerEraser();
      expect(ble.supportedBy(const HelloEvent(2, 239)), isFalse);
      expect(ble.supportedBy(const HelloEvent(3, 239)), isTrue);
      final c = EraseLoggerController(eraser: ble, connect: connectTo(FakeLogger({}, version: 3)));
      await c.start();
      await c.erase();
      expect(c.phase, EraseLoggerPhase.failed);
      expect(c.error, contains('Update the app'));
      expect(logger.sent, [Cmd.hello, Cmd.list]);
    });
  });
}
