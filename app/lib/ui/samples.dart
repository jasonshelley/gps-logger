import 'package:flutter/services.dart';

import '../core/crc32.dart';
import '../data/repository.dart';

/// Built-in sample trips (the test fixtures), for trying the app before the
/// logger has had a GPS fix. They're moved back 52 weeks so they can't clash
/// with real logs, and "Remove sample trips" deletes only them.
Future<int> loadSampleTrips(Repository repo) async {
  const names = ['gps20261108.csv', 'gps20261110.csv'];
  var trips = 0;
  for (final n in names) {
    final data = await rootBundle.load('test/fixtures/$n');
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final r = await repo.importLog('${Repository.samplePrefix}$n', bytes, Crc32.of(bytes),
        shift: const Duration(days: -364));
    trips += r.tripIds.length;
  }
  return trips;
}
