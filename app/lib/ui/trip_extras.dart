import 'package:photo_manager/photo_manager.dart';

import '../core/conditions.dart';
import '../core/photo_match.dart';
import '../data/repository.dart';
import '../main.dart';

// ---- Photos ----

enum PhotoAccess { notAsked, granted, limited, denied }

class TripPhotos {
  const TripPhotos(this.access, this.byCatch, this.unmatched);
  final PhotoAccess access;
  final Map<int, List<AssetEntity>> byCatch;
  final List<AssetEntity> unmatched;

  int get total => byCatch.values.fold(0, (a, l) => a + l.length) + unmatched.length;
}

/// Finds gallery photos taken during a trip and puts each on the nearest catch.
/// Photos never leave the phone; only their timestamps are read.
class PhotoService {
  static const _option = PermissionRequestOption(
    androidPermission: AndroidPermission(type: RequestType.image, mediaLocation: false),
  );

  static PhotoAccess _map(PermissionState s) => switch (s) {
        PermissionState.authorized => PhotoAccess.granted,
        PermissionState.limited => PhotoAccess.limited,
        PermissionState.notDetermined => PhotoAccess.notAsked,
        _ => PhotoAccess.denied,
      };

  static Future<PhotoAccess> current() async => _map(await PhotoManager.getPermissionState(requestOption: _option));

  static Future<PhotoAccess> request() async => _map(await PhotoManager.requestPermissionExtend(requestOption: _option));

  static Future<void> openSettings() => PhotoManager.openSetting();

  /// Lets the person pick more photos when access is limited (Android 14+).
  static Future<void> pickMore() => PhotoManager.presentLimited(type: RequestType.image);

  static Future<TripPhotos> forTrip(TripData d) async {
    final access = await current();
    if (access != PhotoAccess.granted && access != PhotoAccess.limited) {
      return TripPhotos(access, const {}, const []);
    }
    final s = d.trip.stats;
    // Photos up to 30 minutes after the last record still belong to the trip.
    final from = DateTime.fromMillisecondsSinceEpoch(s.startMs - 5 * 60000);
    final to = DateTime.fromMillisecondsSinceEpoch(s.endMs + 30 * 60000);
    final filter = FilterOptionGroup(
      createTimeCond: DateTimeCond(min: from, max: to),
      orders: [const OrderOption(type: OrderOptionType.createDate, asc: true)],
    );
    final count = await PhotoManager.getAssetCount(filterOption: filter, type: RequestType.image);
    if (count == 0) return TripPhotos(access, const {}, const []);
    final assets = await PhotoManager.getAssetListRange(
        start: 0, end: count.clamp(1, 400), filterOption: filter, type: RequestType.image);
    final byId = {for (final a in assets) a.id: a};
    final m = matchPhotos(
      [for (final a in assets) PhotoRef(a.id, a.createDateTime.millisecondsSinceEpoch)],
      [
        for (final c in d.catches)
          if (c.event.t != null) CatchRef(c.id, c.event.t!)
      ],
    );
    return TripPhotos(
      access,
      {for (final e in m.byCatch.entries) e.key: [for (final p in e.value) byId[p.id]!]},
      [for (final p in m.unmatched) byId[p.id]!],
    );
  }
}

// ---- Conditions ----

class TripConditions {
  const TripConditions({this.weather, this.marine, this.error, required this.lat, required this.lon});
  final HourlySeries? weather;
  final HourlySeries? marine;
  final String? error;
  final double lat, lon;

  CatchConditions forCatch(StoredCatch c) => conditionsAt(
        time: c.time!,
        lat: c.event.lat ?? lat,
        lon: c.event.lon ?? lon,
        weather: weather,
        marine: marine,
      );
}

/// Where to ask Open-Meteo about: the middle of the catches, or of the route.
(double, double)? _tripCentre(TripData d) {
  final withPos = d.catches.where((c) => c.event.hasPosition).toList();
  if (withPos.isNotEmpty) {
    final lat = withPos.map((c) => c.event.lat!).reduce((a, b) => a + b) / withPos.length;
    final lon = withPos.map((c) => c.event.lon!).reduce((a, b) => a + b) / withPos.length;
    return (lat, lon);
  }
  final b = d.trip.stats.bounds;
  return b == null ? null : (b.centerLat, b.centerLon);
}

/// Conditions for a trip: from the cache if we have them, else from Open-Meteo.
Future<TripConditions?> loadConditions(AppServices s, TripData d, {bool refresh = false}) async {
  final centre = _tripCentre(d);
  if (centre == null) return null;
  final (lat, lon) = centre;
  final cached = await s.repo.cachedConditions(d.trip.id);
  final stale = cached == null ||
      cached['weather'] == null &&
          DateTime.now().millisecondsSinceEpoch - (cached['fetched_at'] as int) > 3600000;
  if (cached != null && !refresh && !stale) {
    return TripConditions(
      weather: HourlySeries.fromJson(cached['weather'] as String?),
      marine: HourlySeries.fromJson(cached['marine'] as String?),
      lat: lat,
      lon: lon,
    );
  }
  final r = await fetchConditions(s.httpClient,
      lat: lat, lon: lon, start: d.trip.stats.start, end: d.trip.stats.end);
  if (r.weather != null || r.marine != null) {
    await s.repo.saveConditions(d.trip.id, lat, lon, r.weather, r.marine);
  }
  return TripConditions(
    weather: HourlySeries.fromJson(r.weather),
    marine: HourlySeries.fromJson(r.marine),
    error: r.error,
    lat: lat,
    lon: lon,
  );
}
