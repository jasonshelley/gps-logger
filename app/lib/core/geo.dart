import 'dart:math' as math;

const double earthRadiusM = 6371008.8;

double _rad(double d) => d * math.pi / 180;

/// Great-circle distance in metres.
double haversineM(double lat1, double lon1, double lat2, double lon2) {
  final dLat = _rad(lat2 - lat1);
  final dLon = _rad(lon2 - lon1);
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(_rad(lat1)) * math.cos(_rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * earthRadiusM * math.asin(math.min(1.0, math.sqrt(a)));
}

class GeoBounds {
  GeoBounds(this.minLat, this.minLon, this.maxLat, this.maxLon);

  double minLat, minLon, maxLat, maxLon;

  static GeoBounds? of(Iterable<(double, double)> latLons) {
    GeoBounds? b;
    for (final (lat, lon) in latLons) {
      if (b == null) {
        b = GeoBounds(lat, lon, lat, lon);
      } else {
        b.minLat = math.min(b.minLat, lat);
        b.maxLat = math.max(b.maxLat, lat);
        b.minLon = math.min(b.minLon, lon);
        b.maxLon = math.max(b.maxLon, lon);
      }
    }
    return b;
  }

  double get centerLat => (minLat + maxLat) / 2;
  double get centerLon => (minLon + maxLon) / 2;
}
