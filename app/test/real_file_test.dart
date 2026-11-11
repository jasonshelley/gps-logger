import 'dart:io';

import 'package:catch_log/core/crc32.dart';
import 'package:catch_log/data/database.dart';
import 'package:catch_log/data/repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The first real file from the logger (2026-11-11, a few minutes of fix).
void main() {
  sqfliteFfiInit();
  test('the first real file imports into one trip', () async {
    final tmp = await Directory.systemTemp.createTemp('catchlog');
    final db = await openAppDatabase(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final repo = Repository(db, logDir: Directory('${tmp.path}/logs'));
    var notified = 0;
    repo.addListener(() => notified++);
    final bytes = File('test/fixtures/real_gps20261111.csv').readAsBytesSync();
    expect(Crc32.of(bytes), 0xc99eec07);
    final r = await repo.importLog('gps20261111.csv', bytes, Crc32.of(bytes));
    expect(r.newPoints, 7);
    expect(r.tripIds, hasLength(1));
    expect(notified, 1);
    await db.close();
    await tmp.delete(recursive: true);
  });
}
