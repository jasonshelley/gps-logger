/// The movement rule from docs/metrics.md: distance moved and time on the
/// water, with GPS jitter ignored. The logger (src/move_meter.cpp) and the
/// reference (tools/metrics.py) use the same rule, so the phone's figures
/// match the logger's trip meter for the same rows.
library;

import 'dart:math' as math;

import 'log_csv.dart';

/// Points with a higher (or missing) HDOP are ignored.
const double maxHdop = 5.0;

/// The movement threshold is max(25 m, 30 m x HDOP).
const double moveMinM = 25.0;
const double movePerHdopM = 30.0;

/// A move counts once the position has stayed out of the circle this long.
const int confirmS = 30;

/// A longer gap between counted points starts a new segment.
const int moveSegmentGapS = 900;

/// Mean Earth radius, as TinyGPSPlus uses.
const double moveEarthRadiusM = 6371009.0;

double _rad(double d) => d * math.pi / 180;

/// Great-circle distance in metres, in the atan2 form the logger uses
/// (TinyGPSPlus::distanceBetween), so both round the same way.
double moveDistanceM(double lat1, double lon1, double lat2, double lon2) {
  final dl = _rad(lon1 - lon2);
  final sdl = math.sin(dl), cdl = math.cos(dl);
  final p1 = _rad(lat1), p2 = _rad(lat2);
  final s1 = math.sin(p1), c1 = math.cos(p1);
  final s2 = math.sin(p2), c2 = math.cos(p2);
  final a = c1 * s2 - s1 * c2 * cdl;
  final b = c2 * sdl;
  final y = math.sqrt(a * a + b * b);
  final x = s1 * s2 + c1 * c2 * cdl;
  return math.atan2(y, x) * moveEarthRadiusM;
}

double moveThresholdM(double hdop) => math.max(moveMinM, movePerHdopM * hdop);

/// What [MoveMeter.add] did with a point.
enum MoveStep {
  /// HDOP over 5 or missing: the point doesn't count at all.
  ignored,

  /// The first counted point, or one after a gap or a backwards clock: it
  /// starts a new segment and becomes the anchor.
  segmentStart,

  /// Inside the anchor's circle: jitter.
  inside,

  /// Outside the circle, but not for [confirmS] yet.
  pending,

  /// A confirmed move: its distance from the anchor was added and it is the
  /// new anchor.
  moved,
}

/// Distance moved and time on the water from a stream of track points, fed in
/// order. A straight port of `MoveMeter` in tools/metrics.py.
class MoveMeter {
  double distanceM = 0;
  int _closedWaterS = 0;
  int? _lastT; // time of the last counted point (UTC seconds)
  double _anchorLat = 0, _anchorLon = 0; // the last counted position
  int? _outSince; // when the position first left the anchor's circle
  int? _segFirst; // when the segment's first move started
  int? _segLast; // when the segment's last move was counted

  double get anchorLat => _anchorLat;
  double get anchorLon => _anchorLon;

  /// Time on the water: from the first move to the last in each segment,
  /// added up. A segment with no moves counts nothing.
  int get waterS => _closedWaterS + (_segFirst == null ? 0 : _segLast! - _segFirst!);

  /// Feeds one point: [t] in whole UTC seconds, lat/lon and HDOP as written
  /// in the log file.
  MoveStep add(int t, double lat, double lon, double? hdop) {
    if (hdop == null || !(hdop <= maxHdop)) return MoveStep.ignored;
    final last = _lastT;
    if (last == null || t < last || t - last > moveSegmentGapS) {
      if (_segFirst != null) _closedWaterS += _segLast! - _segFirst!;
      _segFirst = _segLast = null;
      _anchorLat = lat;
      _anchorLon = lon;
      _outSince = null;
      _lastT = t;
      return MoveStep.segmentStart;
    }
    _lastT = t;
    final d = moveDistanceM(_anchorLat, _anchorLon, lat, lon);
    if (d < moveThresholdM(hdop)) {
      _outSince = null;
      return MoveStep.inside;
    }
    final out = _outSince ??= t;
    if (t - out < confirmS) return MoveStep.pending;
    distanceM += d;
    _segFirst ??= out;
    _segLast = t;
    _anchorLat = lat;
    _anchorLon = lon;
    _outSince = null;
    return MoveStep.moved;
  }

  MoveStep addPoint(TrackPoint p) => add(p.t ~/ 1000, p.lat, p.lon, p.hdop);
}

/// The route as the map and replay should draw it: points the rule ignores
/// (HDOP over 5) are left out, and jitter is pinned to where the boat sat, so
/// a stationary boat is one dot rather than a scribble. Points that turn out
/// to be part of a real move keep their own positions, so the line follows
/// the boat between moves. Pinned points are given a speed of 0, because the
/// logger's speed reading jitters too (up to 5 km/h on a desk).
List<TrackPoint> displayTrack(List<TrackPoint> points) {
  final out = <TrackPoint>[];
  final meter = MoveMeter();
  var pending = <TrackPoint>[];
  void flushPending({required bool moved, required double lat, required double lon}) {
    for (final p in pending) {
      out.add(moved
          ? p
          : TrackPoint(
              time: p.time,
              lat: lat,
              lon: lon,
              altM: p.altM,
              speedKmh: 0,
              courseDeg: p.courseDeg,
              hdop: p.hdop,
              sats: p.sats,
            ));
    }
    pending = [];
  }

  for (final p in points) {
    // Where the boat sat before this point, for pinning jitter to.
    final lat = meter.anchorLat, lon = meter.anchorLon;
    switch (meter.addPoint(p)) {
      case MoveStep.ignored:
        break;
      case MoveStep.segmentStart:
        // The last segment ended with the position still unconfirmed: jitter.
        flushPending(moved: false, lat: lat, lon: lon);
        // The new anchor waits like any other point: it keeps its speed
        // reading only if a move follows.
        pending.add(p);
      case MoveStep.inside:
        pending.add(p);
        flushPending(moved: false, lat: lat, lon: lon);
      case MoveStep.pending:
        pending.add(p);
      case MoveStep.moved:
        pending.add(p);
        flushPending(moved: true, lat: lat, lon: lon);
    }
  }
  flushPending(moved: false, lat: meter.anchorLat, lon: meter.anchorLon);
  return out;
}
