/// Sun and moon, calculated on the phone. The formulas follow Vladimir
/// Agafonkin's SunCalc (BSD-2), which is based on the astronomy formulas at
/// aa.quae.nl/en/reken/zonpositie.html. Accurate to a minute or two, which is
/// plenty for "an hour after sunrise".
library;

import 'dart:math' as math;

const double _rad = math.pi / 180;
const double _dayMs = 86400000;
const double _j1970 = 2440588;
const double _j2000 = 2451545;
const double _e = _rad * 23.4397; // obliquity of the Earth

double _toJulian(DateTime d) => d.millisecondsSinceEpoch / _dayMs - 0.5 + _j1970;
DateTime _fromJulian(double j) =>
    DateTime.fromMillisecondsSinceEpoch(((j + 0.5 - _j1970) * _dayMs).round(), isUtc: true);
double _toDays(DateTime d) => _toJulian(d) - _j2000;

double _rightAscension(double l, double b) =>
    math.atan2(math.sin(l) * math.cos(_e) - math.tan(b) * math.sin(_e), math.cos(l));
double _declination(double l, double b) =>
    math.asin(math.sin(b) * math.cos(_e) + math.cos(b) * math.sin(_e) * math.sin(l));
double _altitude(double h, double phi, double dec) =>
    math.asin(math.sin(phi) * math.sin(dec) + math.cos(phi) * math.cos(dec) * math.cos(h));
double _siderealTime(double d, double lw) => _rad * (280.16 + 360.9856235 * d) - lw;

double _solarMeanAnomaly(double d) => _rad * (357.5291 + 0.98560028 * d);
double _eclipticLongitude(double m) {
  final c = _rad * (1.9148 * math.sin(m) + 0.02 * math.sin(2 * m) + 0.0003 * math.sin(3 * m));
  const p = _rad * 102.9372; // perihelion of the Earth
  return m + c + p + math.pi;
}

({double dec, double ra}) _sunCoords(double d) {
  final m = _solarMeanAnomaly(d);
  final l = _eclipticLongitude(m);
  return (dec: _declination(l, 0), ra: _rightAscension(l, 0));
}

/// Sun altitude above the horizon in degrees.
double sunAltitudeDeg(DateTime time, double lat, double lon) {
  final lw = _rad * -lon, phi = _rad * lat, d = _toDays(time);
  final c = _sunCoords(d);
  final h = _siderealTime(d, lw) - c.ra;
  return _altitude(h, phi, c.dec) / _rad;
}

class SunTimes {
  const SunTimes({this.sunrise, this.sunset, this.solarNoon, this.dawn, this.dusk});
  final DateTime? sunrise, sunset, solarNoon, dawn, dusk; // UTC; null in polar day/night
}

const double _j0 = 0.0009;
double _julianCycle(double d, double lw) => (d - _j0 - lw / (2 * math.pi)).roundToDouble();
double _approxTransit(double ht, double lw, double n) => _j0 + (ht + lw) / (2 * math.pi) + n;
double _solarTransitJ(double ds, double m, double l) =>
    _j2000 + ds + 0.0053 * math.sin(m) - 0.0069 * math.sin(2 * l);
double _hourAngle(double h, double phi, double d) =>
    math.acos((math.sin(h) - math.sin(phi) * math.sin(d)) / (math.cos(phi) * math.cos(d)));

/// Sunrise, sunset and civil twilight for the day containing [date] at the
/// given place. "The day" is the solar day nearest [date].
SunTimes sunTimes(DateTime date, double lat, double lon) {
  final lw = _rad * -lon, phi = _rad * lat;
  final d = _toDays(date);
  final n = _julianCycle(d, lw);
  final ds = _approxTransit(0, lw, n);
  final m = _solarMeanAnomaly(ds);
  final l = _eclipticLongitude(m);
  final dec = _declination(l, 0);
  final jNoon = _solarTransitJ(ds, m, l);

  DateTime? setFor(double angleDeg, bool rise) {
    final w = _hourAngle(angleDeg * _rad, phi, dec);
    if (w.isNaN) return null;
    final a = _approxTransit(w, lw, n);
    final jSet = _solarTransitJ(a, m, l);
    return _fromJulian(rise ? jNoon - (jSet - jNoon) : jSet);
  }

  return SunTimes(
    solarNoon: _fromJulian(jNoon),
    sunrise: setFor(-0.833, true),
    sunset: setFor(-0.833, false),
    dawn: setFor(-6, true),
    dusk: setFor(-6, false),
  );
}

({double ra, double dec, double distKm}) _moonCoords(double d) {
  final l = _rad * (218.316 + 13.176396 * d);
  final m = _rad * (134.963 + 13.064993 * d);
  final f = _rad * (93.272 + 13.229350 * d);
  final lng = l + _rad * 6.289 * math.sin(m);
  final lat = _rad * 5.128 * math.sin(f);
  final dist = 385001 - 20905 * math.cos(m);
  return (ra: _rightAscension(lng, lat), dec: _declination(lng, lat), distKm: dist);
}

class MoonInfo {
  const MoonInfo(this.fraction, this.phase);

  /// Illuminated fraction, 0 (new) to 1 (full).
  final double fraction;

  /// 0 = new, 0.25 = first quarter, 0.5 = full, 0.75 = last quarter.
  final double phase;

  String get name {
    const names = [
      'New moon',
      'Waxing crescent',
      'First quarter',
      'Waxing gibbous',
      'Full moon',
      'Waning gibbous',
      'Last quarter',
      'Waning crescent',
    ];
    return names[((phase * 8) + 0.5).floor() % 8];
  }

  /// A moon emoji for the phase, for compact display.
  String get emoji => const ['🌑', '🌒', '🌓', '🌔', '🌕', '🌖', '🌗', '🌘'][((phase * 8) + 0.5).floor() % 8];
}

MoonInfo moonIllumination(DateTime time) {
  final d = _toDays(time);
  final s = _sunCoords(d);
  final m = _moonCoords(d);
  const sdist = 149598000; // km from the Earth to the Sun
  final phi = math.acos(math.sin(s.dec) * math.sin(m.dec) +
      math.cos(s.dec) * math.cos(m.dec) * math.cos(s.ra - m.ra));
  final inc = math.atan2(sdist * math.sin(phi), m.distKm - sdist * math.cos(phi));
  final angle = math.atan2(
      math.cos(s.dec) * math.sin(s.ra - m.ra),
      math.sin(s.dec) * math.cos(m.dec) - math.cos(s.dec) * math.sin(m.dec) * math.cos(s.ra - m.ra));
  final fraction = (1 + math.cos(inc)) / 2;
  final phase = 0.5 + 0.5 * inc * (angle < 0 ? -1 : 1) / math.pi;
  return MoonInfo(fraction, phase);
}

/// Moon altitude above the horizon in degrees (useful for "moon overhead").
double moonAltitudeDeg(DateTime time, double lat, double lon) {
  final lw = _rad * -lon, phi = _rad * lat, d = _toDays(time);
  final c = _moonCoords(d);
  final h = _siderealTime(d, lw) - c.ra;
  var alt = _altitude(h, phi, c.dec);
  alt += _rad * 0.017 / math.tan(alt + _rad * 10.26 / (alt + _rad * 5.10)); // refraction
  return alt / _rad;
}
