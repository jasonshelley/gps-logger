import 'log_csv.dart';
import 'trips.dart';

String _esc(String s) => s.replaceAllMapped(RegExp(r'''[<>&"']'''), (m) {
      switch (m[0]) {
        case '<':
          return '&lt;';
        case '>':
          return '&gt;';
        case '&':
          return '&amp;';
        case '"':
          return '&quot;';
        default:
          return '&apos;';
      }
    });

String _iso(DateTime t) {
  final u = t.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}'
      'T${two(u.hour)}:${two(u.minute)}:${two(u.second)}Z';
}

String _coord(double v) => v.toStringAsFixed(6);

/// GPX 1.1 for a trip, matching the Web Bluetooth page's output: catch
/// waypoints first, then one track split into segments at 15-minute gaps.
String buildGpx({
  required String name,
  required List<TrackPoint> points,
  required List<CatchEvent> catches,
}) {
  final b = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<gpx version="1.1" creator="Catch Log" xmlns="http://www.topografix.com/GPX/1/1">')
    ..writeln('  <metadata><name>${_esc(name)}</name></metadata>');

  for (final c in catches) {
    if (!c.hasPosition) continue;
    b.write('  <wpt lat="${_coord(c.lat!)}" lon="${_coord(c.lon!)}">');
    if (c.altM != null) b.write('<ele>${c.altM!.toStringAsFixed(2)}</ele>');
    if (c.time != null) b.write('<time>${_iso(c.time!)}</time>');
    final desc = (c.fixAgeS ?? 0) > 0
        ? 'Position from a fix ${c.fixAgeS} s old'
        : 'Position from the current fix';
    b.writeln('<name>${_esc('${c.angler} catch')}</name><desc>${_esc(desc)}</desc>'
        '<sym>Fishing Area</sym><type>catch</type></wpt>');
  }

  final segs = splitSegments(points);
  if (segs.isNotEmpty) {
    b.writeln('  <trk><name>${_esc(name)}</name>');
    for (final s in segs) {
      b.writeln('    <trkseg>');
      for (final p in s) {
        b.write('      <trkpt lat="${_coord(p.lat)}" lon="${_coord(p.lon)}">');
        if (p.altM != null) b.write('<ele>${p.altM!.toStringAsFixed(2)}</ele>');
        b.write('<time>${_iso(p.time)}</time>');
        if (p.sats != null) b.write('<sat>${p.sats}</sat>');
        if (p.hdop != null) b.write('<hdop>${p.hdop}</hdop>');
        b.writeln('</trkpt>');
      }
      b.writeln('    </trkseg>');
    }
    b.writeln('  </trk>');
  }
  b.writeln('</gpx>');
  return b.toString();
}
