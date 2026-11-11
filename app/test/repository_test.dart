import 'dart:io';
import 'dart:typed_data';

import 'package:catch_log/core/crc32.dart';
import 'package:catch_log/data/database.dart';
import 'package:catch_log/data/repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Repository repo;
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('catchlog');
    final db = await openAppDatabase(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    repo = Repository(db, logDir: Directory('${tmp.path}/logs'));
  });
  tearDown(() async {
    await repo.db.close();
    await tmp.delete(recursive: true);
  });

  Future<ImportResult> import(String name) {
    final bytes = File('test/fixtures/$name').readAsBytesSync();
    return repo.importLog(name, bytes, Crc32.of(bytes));
  }

  test('importing builds trips, keeps the raw file, and is idempotent', () async {
    final r = await import('gps20261108.csv');
    expect(r.alreadyHad, isFalse);
    expect(r.newCatches, 7);
    expect(r.tripIds, hasLength(1));
    final trips = await repo.trips();
    expect(trips, hasLength(1));
    expect(trips.single.stats.catchesByAngler, {'Jase': 4, 'Matt': 3});
    expect(trips.single.stats.distanceM, greaterThan(5000));
    expect(Directory('${tmp.path}/logs').listSync(), hasLength(1));

    final again = await import('gps20261108.csv');
    expect(again.alreadyHad, isTrue);
    expect(await repo.trips(), hasLength(1));
  });

  test('two files, three trips, newest first; trip data loads', () async {
    await import('gps20261108.csv');
    await import('gps20261110.csv');
    final trips = await repo.trips();
    expect(trips, hasLength(3));
    expect(trips.first.stats.startMs, greaterThan(trips.last.stats.startMs));
    final data = await repo.tripData(trips.first.id);
    expect(data!.catches.map((c) => c.angler), ['Jase', 'Jase']);
    expect(data.points.first.t, trips.first.stats.startMs);
  });

  test('a later download of the same day extends the trip', () async {
    final all = File('test/fixtures/gps20261108.csv').readAsStringSync().split('\n');
    final header = all.first;
    final rows = all.skip(1).where((l) => l.isNotEmpty).toList();
    final firstHalf = [header, ...rows.take(400), ''].join('\n');
    final secondHalf = [header, ...rows.skip(400), ''].join('\n');
    final b1 = firstHalf.codeUnits, b2 = secondHalf.codeUnits;
    await repo.importLog('gps20261108.csv', Uint8List.fromList(b1), Crc32.of(b1));
    final before = (await repo.trips()).single;
    final r = await repo.importLog('gps20261108.csv', Uint8List.fromList(b2), Crc32.of(b2));
    expect(r.alreadyHad, isFalse);
    final after = (await repo.trips()).single;
    expect(after.id, before.id);
    expect(after.stats.endMs, greaterThan(before.stats.endMs));
    expect(after.stats.totalCatches, 7);
  });

  test('undated catches are kept outside trips', () async {
    await import('gpsnodate.csv');
    expect(await repo.trips(), isEmpty);
    expect((await repo.undatedCatches()).map((c) => c.angler), ['Jase', 'Matt']);
  });

  test('confirm and conditions cache', () async {
    final bytes = File('test/fixtures/gps20261108.csv').readAsBytesSync();
    final crc = Crc32.of(bytes);
    await repo.importLog('gps20261108.csv', bytes, crc);
    await repo.markConfirmed('gps20261108.csv', crc);
    final row = (await repo.db.query('files')).single;
    expect(row['confirmed_at'], isNotNull);

    final id = (await repo.trips()).single.id;
    expect(await repo.cachedConditions(id), isNull);
    await repo.saveConditions(id, -33.8, 151.2, '{"hourly":{}}', null);
    expect((await repo.cachedConditions(id))!['weather'], '{"hourly":{}}');
  });
}
