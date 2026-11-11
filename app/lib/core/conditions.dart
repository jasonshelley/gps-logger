/// Weather and water conditions for each catch, from Open-Meteo (free, no API
/// key), plus the sun and moon calculated on the phone.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'astro.dart';

/// Hourly values from an Open-Meteo response (`timeformat=unixtime`).
class HourlySeries {
  HourlySeries(this.timesMs, this.values);

  final List<int> timesMs;
  final Map<String, List<double?>> values;

  static HourlySeries? fromJson(String? body) {
    if (body == null || body.isEmpty) return null;
    final j = jsonDecode(body);
    if (j is! Map || j['hourly'] is! Map) return null;
    final h = j['hourly'] as Map;
    final times = [for (final t in (h['time'] as List? ?? const [])) (t as num).toInt() * 1000];
    final values = <String, List<double?>>{};
    h.forEach((k, v) {
      if (k == 'time' || v is! List) return;
      values[k as String] = [for (final x in v) (x as num?)?.toDouble()];
    });
    return HourlySeries(times, values);
  }

  /// [name] at time [tMs], linearly interpolated between the hours either side.
  /// Null if the series doesn't cover the time or the values are missing.
  double? at(String name, int tMs) {
    final v = values[name];
    if (v == null || timesMs.isEmpty) return null;
    if (tMs < timesMs.first || tMs > timesMs.last) return null;
    var i = 0;
    while (i < timesMs.length - 1 && timesMs[i + 1] <= tMs) {
      i++;
    }
    final a = v[i];
    if (i == timesMs.length - 1 || timesMs[i] == tMs) return a;
    final b = v[i + 1];
    if (a == null || b == null) return a ?? b;
    final f = (tMs - timesMs[i]) / (timesMs[i + 1] - timesMs[i]);
    return a + (b - a) * f;
  }

  /// Like [at], for compass directions: picks the nearer hour rather than
  /// averaging (averaging 350° and 10° would give 180°).
  double? nearest(String name, int tMs) {
    final v = values[name];
    if (v == null || timesMs.isEmpty) return null;
    if (tMs < timesMs.first - 3600000 || tMs > timesMs.last + 3600000) return null;
    var best = 0;
    for (var i = 1; i < timesMs.length; i++) {
      if ((timesMs[i] - tMs).abs() < (timesMs[best] - tMs).abs()) best = i;
    }
    return v[best];
  }
}

enum PressureTrend { rising, steady, falling }

class CatchConditions {
  const CatchConditions({
    required this.at,
    required this.sunAltitudeDeg,
    required this.sun,
    required this.moon,
    this.windKn,
    this.windDirDeg,
    this.gustKn,
    this.pressureHpa,
    this.pressureTrend,
    this.airTempC,
    this.waveM,
    this.wavePeriodS,
    this.waveDirDeg,
    this.seaTempC,
  });

  final DateTime at;
  final double sunAltitudeDeg;
  final SunTimes sun;
  final MoonInfo moon;
  final double? windKn, windDirDeg, gustKn;
  final double? pressureHpa;
  final PressureTrend? pressureTrend;
  final double? airTempC;
  final double? waveM, wavePeriodS, waveDirDeg;
  final double? seaTempC;

  bool get hasWeather => windKn != null || pressureHpa != null;
  bool get hasMarine => waveM != null || seaTempC != null;
}

/// Pressure change over the 3 hours before a catch: a classic fishing factor.
PressureTrend? pressureTrendAt(HourlySeries s, int tMs) {
  final now = s.at('pressure_msl', tMs);
  final before = s.at('pressure_msl', tMs - 3 * 3600000);
  if (now == null || before == null) return null;
  final d = now - before;
  if (d >= 1.0) return PressureTrend.rising;
  if (d <= -1.0) return PressureTrend.falling;
  return PressureTrend.steady;
}

CatchConditions conditionsAt({
  required DateTime time,
  required double lat,
  required double lon,
  HourlySeries? weather,
  HourlySeries? marine,
}) {
  final t = time.millisecondsSinceEpoch;
  return CatchConditions(
    at: time,
    sunAltitudeDeg: sunAltitudeDeg(time, lat, lon),
    sun: sunTimes(time, lat, lon),
    moon: moonIllumination(time),
    windKn: weather?.at('wind_speed_10m', t),
    windDirDeg: weather?.nearest('wind_direction_10m', t),
    gustKn: weather?.at('wind_gusts_10m', t),
    pressureHpa: weather?.at('pressure_msl', t),
    pressureTrend: weather == null ? null : pressureTrendAt(weather, t),
    airTempC: weather?.at('temperature_2m', t),
    waveM: marine?.at('wave_height', t),
    wavePeriodS: marine?.at('wave_period', t),
    waveDirDeg: marine?.nearest('wave_direction', t),
    seaTempC: marine?.at('sea_surface_temperature', t),
  );
}

String compassPoint(double deg) {
  const pts = ['N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE', 'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW'];
  return pts[((deg % 360) / 22.5 + 0.5).floor() % 16];
}

/// Builds Open-Meteo request URLs. No API key: Open-Meteo is free for
/// non-commercial use.
class OpenMeteoUrls {
  /// The forecast API serves the last few months; older days come from the
  /// archive (ERA5), which lags real time by about 5 days.
  static const recentDays = 80;

  static String _d(DateTime t) {
    final u = t.toUtc();
    return '${u.year.toString().padLeft(4, '0')}-${u.month.toString().padLeft(2, '0')}-${u.day.toString().padLeft(2, '0')}';
  }

  static Uri weather(double lat, double lon, DateTime start, DateTime end, {DateTime? now}) {
    final recent = (now ?? DateTime.now()).toUtc().difference(start.toUtc()).inDays < recentDays;
    final host = recent ? 'api.open-meteo.com' : 'archive-api.open-meteo.com';
    final path = recent ? '/v1/forecast' : '/v1/archive';
    return Uri.https(host, path, {
      'latitude': lat.toStringAsFixed(4),
      'longitude': lon.toStringAsFixed(4),
      'hourly': 'temperature_2m,pressure_msl,wind_speed_10m,wind_direction_10m,wind_gusts_10m',
      'wind_speed_unit': 'kn',
      'timeformat': 'unixtime',
      'timezone': 'GMT',
      // A day early, so the 3-hour pressure trend works for early catches.
      'start_date': _d(start.subtract(const Duration(days: 1))),
      'end_date': _d(end),
    });
  }

  static Uri marine(double lat, double lon, DateTime start, DateTime end) => Uri.https(
        'marine-api.open-meteo.com',
        '/v1/marine',
        {
          'latitude': lat.toStringAsFixed(4),
          'longitude': lon.toStringAsFixed(4),
          'hourly': 'wave_height,wave_direction,wave_period,sea_surface_temperature',
          'cell_selection': 'sea',
          'timeformat': 'unixtime',
          'timezone': 'GMT',
          'start_date': _d(start),
          'end_date': _d(end),
        },
      );
}

class ConditionsFetch {
  const ConditionsFetch(this.weather, this.marine, this.error);
  final String? weather; // raw JSON, cached as-is
  final String? marine;
  final String? error;
}

/// Fetches both Open-Meteo responses for a trip. Each part fails on its own:
/// inland waters have no marine data, for instance.
Future<ConditionsFetch> fetchConditions(
  http.Client client, {
  required double lat,
  required double lon,
  required DateTime start,
  required DateTime end,
}) async {
  Future<String?> get(Uri u) async {
    final r = await client.get(u).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) return null;
    return r.body;
  }

  String? weather, marine, error;
  try {
    weather = await get(OpenMeteoUrls.weather(lat, lon, start, end));
  } catch (e) {
    error = 'Weather: $e';
  }
  try {
    marine = await get(OpenMeteoUrls.marine(lat, lon, start, end));
  } catch (e) {
    error = error ?? 'Marine: $e';
  }
  if (weather == null && marine == null) error ??= 'Open-Meteo has no data for this trip';
  return ConditionsFetch(weather, marine, error);
}
