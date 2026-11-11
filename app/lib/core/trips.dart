import 'dart:math' as math;

import 'geo.dart';
import 'log_csv.dart';

/// A gap longer than this between records starts a new trip.
const Duration tripGap = Duration(minutes: 45);

/// A gap longer than this inside a trip breaks the route line (the logger was
/// off), the same rule the GPX export uses. No distance is counted across it.
const Duration segmentGap = Duration(minutes: 15);

/// Below this speed the boat counts as stopped (the logger uses the same 2 km/h).
const double movingKmh = 2.0;

/// Speeds above this are treated as GPS glitches.
const double maxPlausibleKmh = 120.0;

class TimeWindow {
  const TimeWindow(this.startMs, this.endMs);
  final int startMs;
  final int endMs;

  Duration get duration => Duration(milliseconds: endMs - startMs);
  bool contains(int t) => t >= startMs && t <= endMs;
  @override
  String toString() => 'TimeWindow($startMs..$endMs)';
}

/// Splits sorted record times (track points and catches) into trips wherever
/// the gap between neighbours is longer than [gap].
List<TimeWindow> splitIntoTrips(List<int> sortedTimes, {Duration gap = tripGap}) {
  final out = <TimeWindow>[];
  if (sortedTimes.isEmpty) return out;
  var start = sortedTimes.first;
  var prev = start;
  for (final t in sortedTimes.skip(1)) {
    if (t - prev > gap.inMilliseconds) {
      out.add(TimeWindow(start, prev));
      start = t;
    }
    prev = t;
  }
  out.add(TimeWindow(start, prev));
  return out;
}

/// Splits a trip's points (sorted by time) into route segments at gaps longer
/// than [gap].
List<List<TrackPoint>> splitSegments(List<TrackPoint> points, {Duration gap = segmentGap}) {
  final segs = <List<TrackPoint>>[];
  List<TrackPoint>? cur;
  TrackPoint? prev;
  for (final p in points) {
    if (cur == null || prev == null || p.t - prev.t > gap.inMilliseconds) {
      cur = <TrackPoint>[];
      segs.add(cur);
    }
    cur.add(p);
    prev = p;
  }
  return segs;
}

class TripStats {
  const TripStats({
    required this.startMs,
    required this.endMs,
    required this.distanceM,
    required this.movingS,
    this.loggedS = 0,
    required this.maxSpeedKmh,
    required this.pointCount,
    required this.catchesByAngler,
    required this.bounds,
  });

  final int startMs;
  final int endMs;
  final double distanceM;
  final int movingS;

  /// Time spent logging: the sum of the gaps between consecutive points in
  /// the same segment (at most 15 min apart). The logger's trip meter counts
  /// "time on the water" the same way.
  final int loggedS;
  final double? maxSpeedKmh;
  final int pointCount;
  final Map<String, int> catchesByAngler;
  final GeoBounds? bounds;

  Duration get duration => Duration(milliseconds: endMs - startMs);
  int get totalCatches => catchesByAngler.values.fold(0, (a, b) => a + b);
  double? get avgMovingKmh => movingS > 0 ? distanceM / movingS * 3.6 : null;
  DateTime get start => DateTime.fromMillisecondsSinceEpoch(startMs, isUtc: true);
  DateTime get end => DateTime.fromMillisecondsSinceEpoch(endMs, isUtc: true);
}

/// Speed between two points: the logger's own speed reading if both have one,
/// otherwise distance over time.
double _legSpeedKmh(TrackPoint a, TrackPoint b, double distM) {
  if (a.speedKmh != null && b.speedKmh != null) return (a.speedKmh! + b.speedKmh!) / 2;
  final dt = (b.t - a.t) / 1000;
  return dt > 0 ? distM / dt * 3.6 : 0;
}

/// Stats for one trip. [points] and [catches] must already be the trip's
/// records; points must be sorted by time.
TripStats computeTripStats(List<TrackPoint> points, List<CatchEvent> catches) {
  var distance = 0.0;
  var moving = 0;
  var loggedMs = 0;
  double? maxSpeed;
  for (final seg in splitSegments(points)) {
    for (var i = 1; i < seg.length; i++) {
      final a = seg[i - 1], b = seg[i];
      final d = haversineM(a.lat, a.lon, b.lat, b.lon);
      final dt = (b.t - a.t) / 1000;
      if (dt <= 0) continue;
      loggedMs += b.t - a.t; // even across a glitch: the logger was logging
      final implied = d / dt * 3.6;
      if (implied > maxPlausibleKmh) continue; // a jump, not a real leg
      distance += d;
      if (_legSpeedKmh(a, b, d) >= movingKmh) moving += dt.round();
    }
  }
  for (final p in points) {
    final s = p.speedKmh;
    if (s != null && s <= maxPlausibleKmh) maxSpeed = math.max(maxSpeed ?? 0, s);
  }

  final byAngler = <String, int>{};
  for (final c in catches) {
    byAngler[c.angler] = (byAngler[c.angler] ?? 0) + 1;
  }

  final times = <int>[
    ...points.map((p) => p.t),
    ...catches.map((c) => c.t).whereType<int>(),
  ];
  final start = times.isEmpty ? 0 : times.reduce(math.min);
  final end = times.isEmpty ? 0 : times.reduce(math.max);

  final bounds = GeoBounds.of([
    ...points.map((p) => (p.lat, p.lon)),
    ...catches.where((c) => c.hasPosition).map((c) => (c.lat!, c.lon!)),
  ]);

  return TripStats(
    startMs: start,
    endMs: end,
    distanceM: distance,
    movingS: moving,
    loggedS: loggedMs ~/ 1000,
    maxSpeedKmh: maxSpeed,
    pointCount: points.length,
    catchesByAngler: byAngler,
    bounds: bounds,
  );
}

/// Position along the route at time [t], linearly interpolated between the
/// neighbouring points. Used by the replay. Returns null for an empty route.
(double lat, double lon)? positionAt(List<TrackPoint> points, int t) {
  if (points.isEmpty) return null;
  if (t <= points.first.t) return (points.first.lat, points.first.lon);
  if (t >= points.last.t) return (points.last.lat, points.last.lon);
  var lo = 0, hi = points.length - 1;
  while (hi - lo > 1) {
    final mid = (lo + hi) >> 1;
    if (points[mid].t <= t) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  final a = points[lo], b = points[hi];
  final f = (t - a.t) / (b.t - a.t);
  return (a.lat + (b.lat - a.lat) * f, a.lon + (b.lon - a.lon) * f);
}

/// Index of the last point at or before [t] (or -1).
int lastIndexAtOrBefore(List<TrackPoint> points, int t) {
  var lo = 0, hi = points.length - 1, ans = -1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (points[mid].t <= t) {
      ans = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return ans;
}
