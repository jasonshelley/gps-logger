import 'dart:io';

import 'package:catch_log/core/meter.dart';
import 'package:catch_log/ui/meter_cards.dart';
import 'package:catch_log/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// How tall the home screen's cards are on the S21 (360 x 800 dp, font scale
/// 1.1), measured with the real Roboto font. layout_test.dart checks nothing
/// overflows using Flutter's test font, whose square glyphs are much wider
/// than Roboto's, so it can't judge size. This file loads Roboto from the
/// Flutter SDK, in its own test isolate so the other tests keep the test font.
Future<bool> _loadRoboto() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return false;
  final dir = Directory('$root/bin/cache/artifacts/material_fonts');
  if (!dir.existsSync()) return false;
  final loader = FontLoader('Roboto');
  for (final w in ['regular', 'medium', 'bold', 'black']) {
    final f = File('${dir.path}/roboto-$w.ttf');
    if (f.existsSync()) loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
  }
  await loader.load();
  return true;
}

void main() {
  late bool roboto;
  setUpAll(() async => roboto = await _loadRoboto());

  Future<(double, double)> measure(WidgetTester tester, MeterReading reading, {DateTime? since, bool queued = false}) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark),
      builder: (c, w) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(1.1)), child: w!),
      home: Scaffold(
        body: ListView(children: [
          TripMeterCard(reading: reading, since: since, resetQueued: queued, onReset: () {}),
          TotalsCard(reading: reading, firstTrip: DateTime.utc(2025, 11, 8, 18)),
        ]),
      ),
    ));
    return (
      tester.getSize(find.byType(TripMeterCard)).height,
      tester.getSize(find.byType(TotalsCard)).height,
    );
  }

  testWidgets('the cards are compact at the S21\'s text size', (tester) async {
    if (!roboto) {
      markTestSkipped('Roboto not found in the Flutter SDK');
      return;
    }
    // Jason's numbers on 11 Nov.
    const today = MeterReading(
      catchesByAngler: {'Jase': 6, 'Matt': 4},
      distanceM: 19600,
      onWater: Duration(hours: 6, minutes: 38),
      trips: 5,
    );
    final (trip, totals) = await measure(tester, today, since: DateTime.utc(2026, 11, 11, 4, 59));
    // ignore: avoid_print
    print('S21, font 1.1: trip meter ${trip.round()} dp, all time ${totals.round()} dp (screen 800 dp)');
    expect(trip, lessThan(160));
    expect(totals, lessThan(160));

    // A huge season, with a reset waiting for the logger: the metrics drop
    // below the four-digit counts, which is fine, but it stays bounded.
    const season = MeterReading(
      catchesByAngler: {'Jase': 1284, 'Matt': 977},
      distanceM: 1287345,
      onWater: Duration(hours: 1287, minutes: 59),
      trips: 342,
    );
    final (trip2, totals2) = await measure(tester, season, since: DateTime.utc(2026, 9, 30, 21), queued: true);
    // ignore: avoid_print
    print('S21, font 1.1, big season: trip meter ${trip2.round()} dp, all time ${totals2.round()} dp');
    expect(trip2, lessThan(260));
    expect(totals2, lessThan(200));
  });
}
