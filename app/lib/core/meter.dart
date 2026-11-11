import 'trips.dart';

/// Catches, distance and time on the water summed over some trips: the trip
/// meter since its last reset, or the all-time totals.
class MeterReading {
  const MeterReading({
    required this.catchesByAngler,
    required this.distanceM,
    required this.onWater,
    required this.trips,
  });

  static const zero = MeterReading(catchesByAngler: {}, distanceM: 0, onWater: Duration.zero, trips: 0);

  final Map<String, int> catchesByAngler;
  final double distanceM;

  /// From the first to the last record of each trip, added up.
  final Duration onWater;

  /// Trips with at least one record in the range.
  final int trips;

  int get catches => catchesByAngler.values.fold(0, (a, b) => a + b);
}

/// Adds up trip stats. [catchesByAngler], when given, replaces the catches
/// counted from the trips (the all-time totals include catches with no time,
/// which belong to no trip).
MeterReading sumTrips(Iterable<TripStats> trips, {Map<String, int>? catchesByAngler}) {
  var distance = 0.0;
  var ms = 0;
  var n = 0;
  final byAngler = <String, int>{};
  for (final s in trips) {
    n++;
    distance += s.distanceM;
    ms += s.endMs - s.startMs;
    s.catchesByAngler.forEach((k, v) => byAngler[k] = (byAngler[k] ?? 0) + v);
  }
  return MeterReading(
    catchesByAngler: catchesByAngler ?? byAngler,
    distanceM: distance,
    onWater: Duration(milliseconds: ms),
    trips: n,
  );
}
