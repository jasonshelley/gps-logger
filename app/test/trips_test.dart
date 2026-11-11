import 'dart:io';

import 'package:catch_log/core/geo.dart';
import 'package:catch_log/core/log_csv.dart';
import 'package:catch_log/core/trips.dart';
import 'package:flutter_test/flutter_test.dart';

TrackPoint pt(int sec, double lat, double lon, [double? kmh, double hdop = 1.0]) => TrackPoint(
    time: DateTime.utc(2026, 11, 8).add(Duration(seconds: sec)), lat: lat, lon: lon, speedKmh: kmh, hdop: hdop);

void main() {
  test('haversine: one degree of latitude is about 111.2 km', () {
    expect(haversineM(-33, 151, -34, 151), closeTo(111195, 5));
    expect(haversineM(-33.8, 151.2, -33.8, 151.2), 0);
  });

  test('records split into trips at gaps over 45 minutes', () {
    const m = 60000;
    final w = splitIntoTrips([0, 1 * m, 30 * m, 75 * m, 200 * m, 201 * m]);
    expect(w.map((e) => (e.startMs, e.endMs)), [(0, 75 * m), (200 * m, 201 * m)]);
    expect(splitIntoTrips([]), isEmpty);
    expect(splitIntoTrips([5]).single.duration, Duration.zero);
  });

  test('route segments break at gaps over 15 minutes', () {
    final segs = splitSegments([pt(0, 0, 0), pt(60, 0, 0), pt(60 + 16 * 60, 0, 0), pt(60 + 17 * 60, 0, 0)]);
    expect(segs.map((s) => s.length), [2, 2]);
  });

  test('stats: distance and time by the movement rule, max speed, catches, span', () {
    final points = [
      pt(0, -33.80, 151.2, 20),
      pt(200, -33.79, 151.2, 20), // 1112 m in 200 s = 20 km/h
      pt(400, -33.78, 151.2, 22),
      pt(460, -33.78, 151.2, 0.5),
      pt(1000, -33.78001, 151.2, 0.4), // drifting, 1 m
    ];
    final catches = [
      CatchEvent(angler: 'Jase', time: DateTime.utc(2026, 11, 8, 0, 5)),
      CatchEvent(angler: 'Matt', time: DateTime.utc(2026, 11, 8, 0, 6)),
      CatchEvent(angler: 'Jase', time: DateTime.utc(2026, 11, 8, 0, 20)),
    ];
    final s = computeTripStats(points, catches);
    // Out of the 30 m circle at 200 s, confirmed at 400 s: one move of
    // 2224 m. The rest sits inside the new circle, so the drift adds nothing.
    expect(s.distanceM, closeTo(2224, 1));
    expect(s.waterS, 200); // from when the move started to when it was counted
    expect(s.maxSpeedKmh, 22);
    expect(s.catchesByAngler, {'Jase': 2, 'Matt': 1});
    expect(s.totalCatches, 3);
    expect(s.duration, const Duration(minutes: 20));
    expect(s.bounds!.minLat, -33.80);
  });

  test('stats ignore GPS jumps, poor fixes and gaps where the logger was off', () {
    final s = computeTripStats([
      pt(0, -33.80, 151.2),
      pt(5, -33.70, 151.2), // 11 km in 5 s, back within 30 s: a glitch
      pt(10, -33.80, 151.2),
      pt(60, -33.70, 151.2, 90, 9.9), // HDOP 9.9: ignored, speed and all
      pt(100, -33.70, 151.2, 90, 9.9),
      pt(10 + 20 * 60, -33.81, 151.2), // after a 20-minute gap: a new anchor
      pt(20 + 20 * 60, -33.8101, 151.2),
    ], const []);
    expect(s.distanceM, 0);
    expect(s.waterS, 0);
    expect(s.maxSpeedKmh, isNull);
    expect(s.bounds!.minLat, -33.81); // the ignored points don't stretch it
    expect(s.bounds!.maxLat, -33.80);
  });

  test('sample day with two trips', () {
    final log = parseLogCsv(File('test/fixtures/gps20261110.csv').readAsStringSync());
    final times = [...log.points.map((p) => p.t), ...log.catches.map((c) => c.t!)]..sort();
    final trips = splitIntoTrips(times);
    expect(trips, hasLength(2));
    final first = computeTripStats(
        log.points.where((p) => trips[0].contains(p.t)).toList(),
        log.catches.where((c) => trips[0].contains(c.t!)).toList());
    expect(first.catchesByAngler, {'Matt': 1});
    expect(first.distanceM, greaterThan(3000));
    expect(first.distanceM, lessThan(15000));
    expect(first.maxSpeedKmh, lessThan(30));
  });

  test('replay position interpolates between points', () {
    final points = [pt(0, -33.0, 151.0), pt(100, -33.1, 151.2)];
    final (lat, lon) = positionAt(points, points.first.t + 50000)!;
    expect(lat, closeTo(-33.05, 1e-9));
    expect(lon, closeTo(151.1, 1e-9));
    expect(positionAt(points, 0), (-33.0, 151.0));
    expect(positionAt(const [], 0), isNull);
    expect(lastIndexAtOrBefore(points, points.first.t - 1), -1);
    expect(lastIndexAtOrBefore(points, points.first.t + 99999), 0);
    expect(lastIndexAtOrBefore(points, points.last.t), 1);
  });
}
