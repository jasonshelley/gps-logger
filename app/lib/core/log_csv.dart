/// Parses the logger's daily CSV files (`gpsYYYYMMDD.csv`, `gpsnodate.csv`).
///
/// Columns (README "CSV columns"): type, time_utc, lat, lon, alt_m, speed_kmh,
/// course_deg, hdop, sats_tracked, sats_visible, fix_quality, fix_mode,
/// fix_age_s, comment. Columns are found by name, so the order may change.
library;

class TrackPoint {
  const TrackPoint({
    required this.time,
    required this.lat,
    required this.lon,
    this.altM,
    this.speedKmh,
    this.courseDeg,
    this.hdop,
    this.sats,
  });

  final DateTime time; // UTC
  final double lat;
  final double lon;
  final double? altM;
  final double? speedKmh;
  final double? courseDeg;
  final double? hdop;
  final int? sats;

  int get t => time.millisecondsSinceEpoch;
}

class CatchEvent {
  const CatchEvent({
    required this.angler,
    this.time,
    this.lat,
    this.lon,
    this.altM,
    this.fixAgeS,
  });

  /// "Jase", "Matt", or whatever name the logger wrote before " catch".
  final String angler;

  /// UTC. Null when the catch was made before the GPS had ever given the date.
  final DateTime? time;

  /// Null when there was no fix at all.
  final double? lat;
  final double? lon;
  final double? altM;

  /// How old the fix used for the position was. 0 = current fix.
  final int? fixAgeS;

  bool get hasPosition => lat != null && lon != null;
  int? get t => time?.millisecondsSinceEpoch;
}

class ParsedLog {
  const ParsedLog({
    required this.points,
    required this.catches,
    required this.badLines,
  });

  final List<TrackPoint> points;
  final List<CatchEvent> catches;

  /// Lines that couldn't be read (wrong type, bad time on a track row...).
  final int badLines;

  int get undatedCatches => catches.where((c) => c.time == null).length;
  int get catchesWithoutPosition => catches.where((c) => !c.hasPosition).length;
}

class LogFormatException implements Exception {
  LogFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

final _decimal = RegExp(r'^-?\d+(\.\d+)?$');

double? _num(String s) => _decimal.hasMatch(s) ? double.parse(s) : null;
int? _int(String s) => RegExp(r'^\d+$').hasMatch(s) ? int.parse(s) : null;

DateTime? _time(String s) {
  if (s.isEmpty) return null;
  // The logger writes e.g. 2026-11-11T08:15:02Z. Only accept full UTC stamps.
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$').hasMatch(s)) {
    return null;
  }
  return DateTime.tryParse(s)?.toUtc();
}

bool _validLatLon(double? lat, double? lon) =>
    lat != null &&
    lon != null &&
    lat.abs() <= 90 &&
    lon.abs() <= 180 &&
    !(lat == 0 && lon == 0);

/// "Jase catch" -> "Jase". Falls back to "Catch" for an empty comment.
String anglerFromComment(String comment) {
  final c = comment.trim();
  if (c.isEmpty) return 'Catch';
  final lower = c.toLowerCase();
  if (lower.endsWith(' catch')) return c.substring(0, c.length - 6).trim();
  return c;
}

ParsedLog parseLogCsv(String csv) {
  final lines = csv.split(RegExp(r'\r?\n')).where((l) => l.isNotEmpty).toList();
  if (lines.isEmpty) {
    return const ParsedLog(points: [], catches: [], badLines: 0);
  }
  final header = lines.first.split(',').map((h) => h.trim()).toList();
  int col(String name) => header.indexOf(name);
  final cType = col('type'), cTime = col('time_utc'), cLat = col('lat');
  final cLon = col('lon'), cAlt = col('alt_m'), cSpeed = col('speed_kmh');
  final cCourse = col('course_deg'), cHdop = col('hdop');
  final cSats = col('sats_tracked'), cAge = col('fix_age_s');
  final cComment = col('comment');
  if (cType < 0 || cLat < 0 || cLon < 0 || cTime < 0) {
    throw LogFormatException('Not a logger CSV (missing columns)');
  }

  final points = <TrackPoint>[];
  final catches = <CatchEvent>[];
  var bad = 0;

  for (final line in lines.skip(1)) {
    final f = line.split(',');
    String get(int i) => i >= 0 && i < f.length ? f[i].trim() : '';
    final type = get(cType);
    final lat = _num(get(cLat));
    final lon = _num(get(cLon));
    final hasPos = _validLatLon(lat, lon);
    final time = _time(get(cTime));

    if (type == 'track') {
      if (!hasPos || time == null) {
        bad++;
        continue;
      }
      points.add(TrackPoint(
        time: time,
        lat: lat!,
        lon: lon!,
        altM: _num(get(cAlt)),
        speedKmh: _num(get(cSpeed)),
        courseDeg: _num(get(cCourse)),
        hdop: _num(get(cHdop)),
        sats: _int(get(cSats)),
      ));
    } else if (type == 'catch') {
      catches.add(CatchEvent(
        angler: anglerFromComment(get(cComment)),
        time: time,
        lat: hasPos ? lat : null,
        lon: hasPos ? lon : null,
        altM: hasPos ? _num(get(cAlt)) : null,
        fixAgeS: _int(get(cAge)),
      ));
    } else {
      bad++;
    }
  }
  return ParsedLog(points: points, catches: catches, badLines: bad);
}
