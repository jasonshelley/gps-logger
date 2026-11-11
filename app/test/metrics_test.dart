import 'dart:io';

import 'package:catch_log/core/crc32.dart';
import 'package:catch_log/core/geo.dart';
import 'package:catch_log/core/log_csv.dart';
import 'package:catch_log/core/move_meter.dart';
import 'package:catch_log/core/trips.dart';
import 'package:catch_log/data/database.dart';
import 'package:catch_log/data/repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The movement rule (docs/metrics.md) against the shared fixtures in
/// ../test-data/. The expected numbers are what tools/metrics.py prints, and
/// what the logger's meter shows for the same rows:
///
///     python tools/metrics.py test-data/stationary-desk.csv test-data/moving-noisy.csv
///
/// They match exactly. The logger reports whole metres, so distances are
/// compared rounded to the metre; times are whole seconds already.
const _desk = '../test-data/stationary-desk.csv';
const _moving = '../test-data/moving-noisy.csv';

ParsedLog _parse(String path) => parseLogCsv(File(path).readAsStringSync());

void main() {
  test('the distance formula is the logger\'s atan2 form with R = 6 371 009 m', () {
    expect(moveDistanceM(-33, 151, -34, 151), closeTo(111195.08, 0.01));
    expect(moveDistanceM(-33.8, 151.2, -33.8, 151.2), 0);
    expect(moveThresholdM(0.7), 25);
    expect(moveThresholdM(2.2), closeTo(66, 1e-9));
  });

  group('the shared fixtures', () {
    test('a logger left on the desk moved nowhere', () {
      final log = _parse(_desk);
      expect(log.points, hasLength(313));
      final s = computeTripStats(log.points, log.catches);
      expect(s.distanceM.round(), 0);
      expect(s.waterS, 0);
    });

    test('a noisy day on the water: 6667 m (true 6831 m) and 11 205 s', () {
      final log = _parse(_moving);
      final s = computeTripStats(log.points, log.catches);
      expect(s.distanceM.round(), 6667);
      expect(s.waterS, 11205);
      expect(s.onWater, const Duration(hours: 3, minutes: 6, seconds: 45));
      expect(s.catchesByAngler, {'Jase': 1, 'Matt': 1});
    });

    test('the meter fed point by point gives the same numbers', () {
      for (final (path, metres, seconds) in [(_desk, 0, 0), (_moving, 6667, 11205)]) {
        final m = MoveMeter();
        for (final p in _parse(path).points) {
          m.addPoint(p);
        }
        expect((m.distanceM.round(), m.waterS), (metres, seconds), reason: path);
      }
    });
  });

  group('the trip meter and totals', () {
    sqfliteFfiInit();
    late Repository repo;
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('catchlog');
      final db = await openAppDatabase(factory: databaseFactoryFfi, path: '${tmp.path}/catch_log.db');
      repo = Repository(db, logDir: Directory('${tmp.path}/logs'));
      for (final (path, name) in [(_moving, 'gps20261108.csv'), (_desk, 'gps20261111.csv')]) {
        final bytes = File(path).readAsBytesSync();
        await repo.importLog(name, bytes, Crc32.of(bytes));
      }
    });
    tearDown(() async {
      await repo.db.close();
      await tmp.delete(recursive: true);
    });

    test('the totals add up both files', () async {
      final trips = await repo.trips();
      expect(trips, hasLength(2));
      final all = await repo.totals();
      expect(all.distanceM.round(), 6667);
      expect(all.onWater.inSeconds, 11205);
      expect(all.catchesByAngler, {'Jase': 1, 'Matt': 1});
    });

    test('the trip list thumbnails draw the route without the jitter', () async {
      final trips = await repo.trips();
      final desk = trips.firstWhere((t) => t.stats.start.day == 11);
      final moving = trips.firstWhere((t) => t.stats.start.day == 8);
      expect(await repo.routePreview(desk), hasLength(1)); // a dot
      final route = await repo.routePreview(moving);
      expect(route.length, greaterThan(20));
      expect(route.length, lessThanOrEqualTo(91));
    });

    test('a reset part way through a trip counts from the reset, as tools/metrics.py does', () async {
      // meter_for(['test-data/moving-noisy.csv'], reset) in tools/metrics.py.
      for (final (reset, metres, seconds, matt) in [
        (DateTime.utc(2026, 11, 8, 21), 4199, 5744, 1),
        (DateTime.utc(2026, 11, 8, 22, 30), 3231, 2238, 0),
        (DateTime.utc(2026, 11, 8, 23), 797, 514, 0),
      ]) {
        await repo.resetMeter(at: reset);
        final m = await repo.meter();
        expect((m.distanceM.round(), m.onWater.inSeconds), (metres, seconds), reason: '$reset');
        expect(m.catchesByAngler['Jase'] ?? 0, 0, reason: '$reset');
        expect(m.catchesByAngler['Matt'] ?? 0, matt, reason: '$reset');
      }
    });
  });

  group('the map', () {
    // Length of the line the map draws: legs within a stretch of logging.
    double drawnM(List<TrackPoint> t) {
      var d = 0.0;
      for (var i = 1; i < t.length; i++) {
        if (t[i].t - t[i - 1].t <= moveSegmentGapS * 1000) d += haversineM(t[i - 1].lat, t[i - 1].lon, t[i].lat, t[i].lon);
      }
      return d;
    }

    test('a stationary logger draws as a dot, not a scribble', () {
      final log = _parse(_desk);
      expect(drawnM(log.points), greaterThan(3000)); // the jitter, as logged
      final track = displayTrack(log.points);
      expect(track, hasLength(log.points.length));
      expect(drawnM(track), 0);
      // One dot per stretch of logging: the file has a 30-minute gap.
      expect({for (final p in track) (p.lat, p.lon)}, hasLength(2));
      // The logger's speed reading jitters too (up to 5.2 km/h here), but
      // the map shades it all as stopped, and there's no max speed.
      expect(log.points.map((p) => p.speedKmh!).reduce((a, b) => a > b ? a : b), greaterThan(5));
      expect(track.every((p) => p.speedKmh == 0), isTrue);
      expect(computeTripStats(log.points, const []).maxSpeedKmh, isNull);
    });

    test('a moving boat draws close to its true 6831 m', () {
      final log = _parse(_moving);
      expect(drawnM(log.points), greaterThan(8000)); // with the jitter at the stops
      final track = displayTrack(log.points);
      expect(track, hasLength(log.points.length)); // nothing has HDOP over 5
      expect(drawnM(track), closeTo(6831, 6831 * 0.02));
      // Times are untouched, so the replay keeps its pace.
      expect([for (final p in track) p.t], [for (final p in log.points) p.t]);
    });

    test('points with a poor fix are left off the map', () {
      TrackPoint at(int s, double lat, double hdop) =>
          TrackPoint(time: DateTime.utc(2026, 11, 8).add(Duration(seconds: s)), lat: lat, lon: 151.2, hdop: hdop);
      final track = displayTrack([at(0, -33.8, 1), at(10, -33.0, 25.5), at(20, -33.8, 1)]);
      expect([for (final p in track) p.t ~/ 1000 % 60], [0, 20]);
    });
  });
}
