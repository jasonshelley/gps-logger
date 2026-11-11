import 'dart:io';

import 'package:catch_log/core/gpx.dart';
import 'package:catch_log/core/log_csv.dart';
import 'package:flutter_test/flutter_test.dart';

const header = 'type,time_utc,lat,lon,alt_m,speed_kmh,course_deg,hdop,sats_tracked,'
    'sats_visible,fix_quality,fix_mode,fix_age_s,comment';

void main() {
  test('parses the README example rows', () {
    final log = parseLogCsv('$header\n'
        'track,2026-11-11T08:15:02Z,-33.865143,151.209900,12.34,5.20,123.45,1.2,9,14,1,A,,\n'
        'catch,2026-11-11T08:16:40Z,-33.865200,151.209950,12.00,0.40,10.00,1.1,9,14,1,A,0,Jase catch\n');
    expect(log.points, hasLength(1));
    final p = log.points.single;
    expect(p.time, DateTime.utc(2026, 11, 11, 8, 15, 2));
    expect((p.lat, p.lon, p.altM, p.speedKmh, p.courseDeg, p.hdop, p.sats),
        (-33.865143, 151.2099, 12.34, 5.2, 123.45, 1.2, 9));
    final c = log.catches.single;
    expect(c.angler, 'Jase');
    expect(c.fixAgeS, 0);
    expect(c.hasPosition, isTrue);
    expect(log.badLines, 0);
  });

  test('handles CRLF, blank lines and a reordered header', () {
    final log = parseLogCsv('time_utc,type,lon,lat,comment,fix_age_s\r\n'
        '2026-11-11T08:15:02Z,track,151.2,-33.8,,\r\n\r\n'
        '2026-11-11T08:16:02Z,catch,151.3,-33.9,Matt catch,45\r\n');
    expect(log.points.single.lat, -33.8);
    expect(log.points.single.lon, 151.2);
    expect(log.catches.single.angler, 'Matt');
    expect(log.catches.single.fixAgeS, 45);
  });

  test('catches with no date or no position are kept, track rows without are skipped', () {
    final log = parseLogCsv(File('test/fixtures/gpsnodate.csv').readAsStringSync());
    expect(log.catches.map((c) => c.angler), ['Jase', 'Matt']);
    expect(log.undatedCatches, 2);
    expect(log.catchesWithoutPosition, 2);

    final bad = parseLogCsv('$header\n'
        'track,,-33.8,151.2,,,,,,,,,,\n' // no time
        'track,2026-11-11T08:15:02Z,,,,,,,,,,,,\n' // no position
        'track,2026-11-11T08:15:02Z,-33.8,abc,,,,,,,,,,\n' // junk number
        'track,2026-11-11T08:15:02Z,0.000000,0.000000,,,,,,,,,,\n' // null island
        'banana,2026-11-11T08:15:02Z,-33.8,151.2,,,,,,,,,,\n');
    expect(bad.points, isEmpty);
    expect(bad.badLines, 5);
  });

  test('rejects a file that is not a logger CSV', () {
    expect(() => parseLogCsv('name,value\nx,1\n'), throwsA(isA<LogFormatException>()));
    expect(parseLogCsv('').points, isEmpty);
  });

  test('angler names come from the comment', () {
    expect(anglerFromComment('Jase catch'), 'Jase');
    expect(anglerFromComment('Matt Catch'), 'Matt');
    expect(anglerFromComment(''), 'Catch');
    expect(anglerFromComment('Bob'), 'Bob');
  });

  test('the sample trip parses fully', () {
    final log = parseLogCsv(File('test/fixtures/gps20261108.csv').readAsStringSync());
    expect(log.badLines, 0);
    expect(log.points.length, greaterThan(500));
    expect(log.catches.where((c) => c.angler == 'Jase'), hasLength(4));
    expect(log.catches.where((c) => c.angler == 'Matt'), hasLength(3));
    expect(log.catches.where((c) => (c.fixAgeS ?? 0) > 0), hasLength(1));
  });

  group('GPX', () {
    test('has waypoints for catches with a position and splits segments at gaps', () {
      final log = parseLogCsv(File('test/fixtures/gps20261108.csv').readAsStringSync());
      final gpx = buildGpx(name: 'gps20261108', points: log.points, catches: log.catches);
      expect(RegExp('<wpt ').allMatches(gpx), hasLength(7));
      expect(RegExp('<trkpt ').allMatches(gpx), hasLength(log.points.length));
      // The fixture switches the logger off for 20 minutes once.
      expect(RegExp('<trkseg>').allMatches(gpx), hasLength(2));
      expect(gpx, contains('<name>Matt catch</name><desc>Position from a fix 1230 s old</desc>'));
      expect(gpx, startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
    });

    test('escapes names and skips catches without a position', () {
      final gpx = buildGpx(name: 'A & B <trip>', points: const [], catches: const [
        CatchEvent(angler: 'Jase'),
      ]);
      expect(gpx, contains('A &amp; B &lt;trip&gt;'));
      expect(gpx, isNot(contains('<wpt')));
      expect(gpx, isNot(contains('<trk>')));
    });
  });
}
