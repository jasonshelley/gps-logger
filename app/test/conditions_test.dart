import 'dart:convert';

import 'package:catch_log/core/astro.dart';
import 'package:catch_log/core/conditions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('sun and moon', () {
    // Sydney, 8 Nov 2026. Published times (AEDT): sunrise 05:49, sunset 19:30.
    const lat = -33.8688, lon = 151.2093;

    test('Sydney sunrise and sunset within 3 minutes', () {
      final s = sunTimes(DateTime.utc(2026, 11, 8, 2), lat, lon);
      final rise = s.sunrise!.add(const Duration(hours: 11));
      final set = s.sunset!.add(const Duration(hours: 11));
      expect(rise.difference(DateTime.utc(2026, 11, 8, 5, 49)).inMinutes.abs(), lessThanOrEqualTo(3));
      expect(set.difference(DateTime.utc(2026, 11, 8, 19, 30)).inMinutes.abs(), lessThanOrEqualTo(3));
      expect(s.dawn!.isBefore(s.sunrise!), isTrue);
    });

    test('sun is up at noon and down at midnight', () {
      expect(sunAltitudeDeg(DateTime.utc(2026, 11, 8, 2), lat, lon), greaterThan(60));
      expect(sunAltitudeDeg(DateTime.utc(2026, 11, 8, 14), lat, lon), lessThan(-20));
    });

    test('moon phases on known dates', () {
      // Full moon 2026-11-24 14:53 UTC; new moon 2026-11-09 07:02 UTC.
      final full = moonIllumination(DateTime.utc(2026, 11, 24, 15));
      expect(full.fraction, greaterThan(0.98));
      expect(full.name, 'Full moon');
      final newMoon = moonIllumination(DateTime.utc(2026, 11, 9, 7));
      expect(newMoon.fraction, lessThan(0.02));
      expect(newMoon.name, 'New moon');
      final waxing = moonIllumination(DateTime.utc(2026, 11, 13));
      expect(waxing.name, 'Waxing crescent');
    });
  });

  group('Open-Meteo', () {
    final t0 = DateTime.utc(2026, 11, 8).millisecondsSinceEpoch ~/ 1000;
    String body(Map<String, List<num?>> series) => jsonEncode({
          'hourly': {
            'time': [for (var i = 0; i < series.values.first.length; i++) t0 + i * 3600],
            ...series,
          }
        });

    test('values interpolate between hours and directions take the nearer hour', () {
      final s = HourlySeries.fromJson(body({
        'wind_speed_10m': [10, 20, null],
        'wind_direction_10m': [350, 10, 20],
      }))!;
      final half = (t0 + 1800) * 1000;
      expect(s.at('wind_speed_10m', half), 15);
      expect(s.at('wind_speed_10m', (t0 + 5400) * 1000), 20); // next value missing
      expect(s.nearest('wind_direction_10m', (t0 + 1700) * 1000), 350);
      expect(s.nearest('wind_direction_10m', (t0 + 1900) * 1000), 10);
      expect(s.at('wind_speed_10m', (t0 - 10) * 1000), isNull);
      expect(s.at('nope', half), isNull);
    });

    test('pressure trend over 3 hours', () {
      final s = HourlySeries.fromJson(body({'pressure_msl': [1015, 1014.5, 1014, 1012.8, 1014]}))!;
      expect(pressureTrendAt(s, (t0 + 3 * 3600) * 1000), PressureTrend.falling);
      expect(pressureTrendAt(s, (t0 + 4 * 3600) * 1000), PressureTrend.steady);
      expect(pressureTrendAt(s, t0 * 1000), isNull);
    });

    test('bad bodies give no series', () {
      expect(HourlySeries.fromJson(null), isNull);
      expect(HourlySeries.fromJson('{"error":true,"reason":"x"}'), isNull);
    });

    test('URLs: forecast for recent trips, archive for old ones, marine always', () {
      final start = DateTime.utc(2026, 11, 7, 18), end = DateTime.utc(2026, 11, 7, 23);
      final recent = OpenMeteoUrls.weather(-33.84, 151.26, start, end, now: DateTime.utc(2026, 11, 11));
      expect(recent.host, 'api.open-meteo.com');
      expect(recent.queryParameters['start_date'], '2026-11-06');
      expect(recent.queryParameters['end_date'], '2026-11-07');
      expect(recent.queryParameters['wind_speed_unit'], 'kn');
      final old = OpenMeteoUrls.weather(-33.84, 151.26, start, end, now: DateTime.utc(2027, 6, 1));
      expect(old.host, 'archive-api.open-meteo.com');
      final marine = OpenMeteoUrls.marine(-33.84, 151.26, start, end);
      expect(marine.host, 'marine-api.open-meteo.com');
      expect(marine.queryParameters['hourly'], contains('sea_surface_temperature'));
      expect(marine.toString(), isNot(contains('key')));
    });

    test('fetch: marine failing on its own still gives weather', () async {
      final client = MockClient((req) async {
        if (req.url.host.startsWith('marine')) return http.Response('{"error":true}', 400);
        return http.Response(body({'pressure_msl': [1010, 1011]}), 200);
      });
      final r = await fetchConditions(client,
          lat: -33.84, lon: 151.26, start: DateTime.utc(2026, 11, 8), end: DateTime.utc(2026, 11, 8, 1));
      expect(r.weather, isNotNull);
      expect(r.marine, isNull);
      expect(r.error, isNull);
    });

    test('conditionsAt combines everything for a catch', () {
      final weather = HourlySeries.fromJson(body({
        'wind_speed_10m': [8, 12, 12, 12, 12],
        'wind_direction_10m': [45, 45, 45, 45, 45],
        'pressure_msl': [1016, 1015, 1014, 1013, 1012],
        'temperature_2m': [18, 19, 20, 21, 22],
      }));
      final marine = HourlySeries.fromJson(body({
        'wave_height': [0.6, 0.8, 0.8, 0.8, 0.8],
        'sea_surface_temperature': [19.5, 19.6, 19.7, 19.8, 19.9],
      }));
      final c = conditionsAt(
          time: DateTime.utc(2026, 11, 8, 3), lat: -33.84, lon: 151.26, weather: weather, marine: marine);
      expect(c.windKn, 12);
      expect(compassPoint(c.windDirDeg!), 'NE');
      expect(c.pressureTrend, PressureTrend.falling);
      expect(c.seaTempC, closeTo(19.8, 1e-9));
      expect(c.hasWeather && c.hasMarine, isTrue);
      expect(c.sunAltitudeDeg, greaterThan(50));
    });
  });
}
