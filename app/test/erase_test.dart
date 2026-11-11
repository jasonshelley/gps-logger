import 'dart:io';
import 'dart:typed_data';

import 'package:catch_log/ble/protocol.dart';
import 'package:catch_log/core/crc32.dart';
import 'package:catch_log/data/database.dart';
import 'package:catch_log/data/repository.dart';
import 'package:catch_log/sync/logger_eraser.dart';
import 'package:catch_log/sync/logger_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_logger.dart';

const _zero = MeterEvent(resetUtcSeconds: 1794384000, jase: 0, matt: 0, distanceM: 0, waterS: 0, flags: 0);

/// A stand-in eraser, for the controller's own logic.
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
    return const LoggerEraseResult(deletedFiles: 7, meter: _zero);
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
      final c = EraseLoggerController(
          eraser: eraser, connect: connectTo(FakeLogger({'gps20261111.csv': [1, 2]}, version: 2)));
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

    test('ERASE_LOGS and ERASED match the example in docs/ble-protocol.md', () {
      expect(encodeEraseLogs(), [0x08, 0x45, 0x52, 0x41, 0x53]);
      final e = decodeEvent(Uint8List.fromList([0x88, 0x04, 0x00, 0x00, 0x00, 0x00])) as ErasedEvent;
      expect((e.deleted, e.failed, e.resetNotSaved), (4, 0, false));
      final f = decodeEvent(Uint8List.fromList([0x88, 0x01, 0x01, 0x02, 0x00, 0x01])) as ErasedEvent;
      expect((f.deleted, f.failed, f.resetNotSaved), (257, 2, true));
      final m = decodeEvent(Uint8List.fromList(
          [0x87, 0x80, 0x20, 0xf4, 0x6a, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])) as MeterEvent;
      expect(m.resetAt, DateTime.utc(2026, 11, 11, 8));
      expect(() => decodeEvent(Uint8List.fromList([0x88, 1, 0, 0])), throwsA(isA<ProtocolException>()));
      expect(describeLoggerError(10, ''), contains('Nothing was erased'));
    });

    group('over the real command, against the fake logger', () {
      test('erases the root and /uploaded logs, and the phone\'s meter takes the logger\'s reset', () async {
        await repo.resetMeter(at: DateTime.utc(2026, 11, 10)); // queued, now overtaken
        final fake = FakeLogger({'gps20261111.csv': List.filled(50, 65)}, version: 3)
          ..uploaded['gps20261110.csv'] = Uint8List(10)
          ..clockUtc = 1794384000;
        final c = EraseLoggerController(connect: connectTo(fake), onMeterReset: repo.meterResetByLogger);
        await c.start();
        expect(c.unsynced.single.name, 'gps20261111.csv');
        await c.erase();
        expect(c.phase, EraseLoggerPhase.done, reason: c.error);
        expect(c.result!.deletedFiles, 2);
        expect(c.result!.failedFiles, 0);
        expect(c.remaining, isEmpty);
        expect(fake.files, isEmpty);
        expect(fake.uploaded, isEmpty);
        expect(fake.sent, [Cmd.hello, Cmd.list, Cmd.eraseLogs]);
        final at = DateTime.utc(2026, 11, 11, 8);
        expect(c.result!.meter.resetAt, at);
        expect(c.phoneResetAt, at);
        expect(await repo.meterResetAt(), at);
        expect(await repo.pendingMeterReset(), isNull); // the logger already has it
      });

      test('files that couldn\'t be deleted are reported, with the next LIST', () async {
        final fake = FakeLogger({'gps20261111.csv': [65], 'gpsnodate.csv': [65]}, version: 3)
          ..uploaded['gps20261109.csv'] = Uint8List(3)
          ..undeletable = {'gps20261111.csv', 'gps20261109.csv'}
          ..erasedFlags = 1;
        final c = EraseLoggerController(connect: connectTo(fake), onMeterReset: repo.meterResetByLogger);
        await c.start();
        await c.erase();
        expect(c.phase, EraseLoggerPhase.done);
        expect((c.result!.deletedFiles, c.result!.failedFiles, c.result!.resetNotSaved), (1, 2, true));
        // LIST shows the root folder only, so the /uploaded one isn't named.
        expect(c.remaining.map((f) => f.name), ['gps20261111.csv']);
        expect(fake.sent, [Cmd.hello, Cmd.list, Cmd.eraseLogs, Cmd.list]);
      });

      test('a logger with no GPS time resets to 0; the phone counts from now and tells it next sync', () async {
        final fake = FakeLogger({}, version: 3)..clockUtc = 0;
        final c = EraseLoggerController(connect: connectTo(fake), onMeterReset: repo.meterResetByLogger);
        final before = DateTime.now().subtract(const Duration(seconds: 1));
        await c.start();
        await c.erase();
        expect(c.result!.meter.resetAt, isNull);
        expect(c.result!.meter.clockNotSet, isTrue);
        expect(c.phoneResetAt!.isAfter(before), isTrue);
        expect(await repo.pendingMeterReset(), c.phoneResetAt);
      });

      test('busy or no card: nothing is erased, and the phone\'s meter is left alone', () async {
        for (final code in [4, 5]) {
          final reset = await repo.resetMeter(at: DateTime.utc(2026, 11, 10));
          final fake = FakeLogger({'gps20261111.csv': [65]}, version: 3)..eraseError = code;
          final c = EraseLoggerController(connect: connectTo(fake), onMeterReset: repo.meterResetByLogger);
          await c.start();
          await c.erase();
          expect(c.phase, EraseLoggerPhase.failed);
          expect(c.error, endsWith('Nothing was erased.'));
          expect(fake.files, hasLength(1));
          expect(await repo.meterResetAt(), reset);
          expect(await repo.pendingMeterReset(), reset);
        }
      });
    });
  });
}
