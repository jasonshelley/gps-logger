import 'dart:io';

import 'package:catch_log/core/crc32.dart';
import 'package:catch_log/data/database.dart';
import 'package:catch_log/data/repository.dart';
import 'package:catch_log/main.dart';
import 'package:catch_log/ble/protocol.dart';
import 'package:catch_log/sync/logger_meter.dart';
import 'package:catch_log/sync/sync_controller.dart';
import 'package:catch_log/sync/logger_eraser.dart';
import 'package:catch_log/ui/catch_card.dart';
import 'package:catch_log/ui/erase.dart';
import 'package:catch_log/ui/home_screen.dart';
import 'package:catch_log/ui/meter_cards.dart';
import 'package:catch_log/ui/sync_screen.dart';
import 'package:catch_log/ui/theme.dart';
import 'package:catch_log/ui/trip_screen.dart';
import 'package:catch_log/ui/widgets.dart';
import 'package:catch_log/core/astro.dart';
import 'package:catch_log/core/meter.dart';
import 'package:catch_log/core/conditions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Renders each screen at the Galaxy S21's size (1080 x 2400 px at 480 dpi,
/// so 360 x 800 dp) with font scales from normal up to the largest Android
/// offers, and fails on any overflow (the yellow-and-black stripes).
///
/// The trip screen itself isn't covered here: its map is a platform view.
/// Its parts (the stats grid and the catch cards) are tested on their own.
const s21 = Size(360, 800);
const fontScales = [1.0, 1.1, 1.3, 1.5, 2.0];

class _IdleSync extends SyncController {
  _IdleSync(super.repo);
  @override
  Future<void> start() async {}
  void show(SyncPhase p) {
    phase = p;
    notifyListeners();
  }
}

/// An erase controller that only shows the state it's given.
class _ShownErase extends EraseLoggerController {
  void show(EraseLoggerPhase p) {
    phase = p;
    notifyListeners();
  }
}

Future<Repository> _repoWithFixtures(Directory tmp, {bool fixtures = true}) async {
  final db = await openAppDatabase(factory: databaseFactoryFfi, path: '${tmp.path}/catch_log.db');
  final repo = Repository(db, logDir: Directory('${tmp.path}/logs'));
  if (fixtures) {
    for (final f in ['gps20261108.csv', 'gps20261110.csv', 'gpsnodate.csv']) {
      final bytes = File('test/fixtures/$f').readAsBytesSync();
      await repo.importLog(f, bytes, Crc32.of(bytes));
    }
  }
  return repo;
}

Widget _app(AppServices services, Widget home, double scale, {Brightness b = Brightness.light}) => AppScope(
      services: services,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(b),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: home,
      ),
    );

void _useS21(WidgetTester tester) {
  tester.view.physicalSize = s21 * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

final _errors = <String>[];

/// Layout errors since the last call, each with the widget that caused it.
List<String> _overflows(WidgetTester tester) {
  final out = List<String>.of(_errors);
  _errors.clear();
  return out;
}

/// A widget test that records every layout error rather than only the first.
void sweep(String name, Future<void> Function(WidgetTester tester) body) {
  testWidgets(name, (tester) async {
    final old = FlutterError.onError;
    FlutterError.onError = (d) {
      final text = d.toString();
      final where = RegExp(r'lib/ui/[a-z_]+\.dart:\d+:\d+').allMatches(text).map((m) => m[0]).toSet();
      _errors.add('${d.exceptionAsString().split('\n').first} at ${where.join(', ')}');
    };
    try {
      await body(tester);
    } finally {
      FlutterError.onError = old;
      _errors.clear();
    }
  });
}

void _noop() {}

/// The meter cards take their numbers as arguments; they never touch the database.
class _NoDb implements Database {
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

void main() {
  sqfliteFfiInit();

  for (final scale in fontScales) {
    sweep('home with trips fits at font ×$scale', (tester) async {
      _useS21(tester);
      final tmp = Directory.systemTemp.createTempSync('catchlog');
      final repo = await tester.runAsync(() => _repoWithFixtures(tmp));
      final services = AppServices(repo: repo!, httpClient: MockClient((_) async => http.Response('', 500)));
      await tester.pumpWidget(_app(services, const HomeScreen(), scale));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Catch Log'), findsWidgets);
      expect(_overflows(tester), isEmpty);
      // Scroll through the whole list; the trip cards may start off screen.
      var sawTrips = tester.any(find.byType(TripCard));
      for (var i = 0; i < 6; i++) {
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 300));
        expect(_overflows(tester), isEmpty, reason: 'after scrolling ${i + 1} screens');
        sawTrips |= tester.any(find.byType(TripCard));
      }
      expect(sawTrips, isTrue);
      await tester.runAsync(() => repo.db.close());
    });

    sweep('empty home fits at font ×$scale', (tester) async {
      _useS21(tester);
      final tmp = Directory.systemTemp.createTempSync('catchlog');
      final repo = await tester.runAsync(() => _repoWithFixtures(tmp, fixtures: false));
      final services = AppServices(repo: repo!, httpClient: MockClient((_) async => http.Response('', 500)));
      await tester.pumpWidget(_app(services, const HomeScreen(), scale));
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('No trips yet'), findsOneWidget);
      expect(_overflows(tester), isEmpty);
      await tester.runAsync(() => repo.db.close());
    });

    sweep('every sync screen state fits at font ×$scale', (tester) async {
      _useS21(tester);
      final tmp = Directory.systemTemp.createTempSync('catchlog');
      final repo = await tester.runAsync(() => _repoWithFixtures(tmp, fixtures: false));
      final sync = _IdleSync(repo!);
      final services = AppServices(repo: repo, httpClient: MockClient((_) async => http.Response('', 500)), sync: sync);
      await tester.pumpWidget(_app(services, const SyncScreen(), scale));
      for (final p in SyncPhase.values) {
        sync.deviceName = 'GPS Logger';
        sync.error = p == SyncPhase.failed
            ? 'The connection to the logger dropped. Files already synced are safe; the rest are still on the logger.'
            : null;
        sync.files = [
          FileProgress('gps20261108.csv', 48211)..state = FileState.done,
          FileProgress('gps20261109.csv', 683)
            ..state = FileState.done
            ..alreadyHad = true,
          FileProgress('gps20261110.csv', 120344)
            ..state = FileState.downloading
            ..received = 40000,
          FileProgress('gps20261111.csv', 9000)
            ..state = FileState.failed
            ..error = 'CRC mismatch: the file was damaged on the way. It stays on the logger.',
          FileProgress('gpsnodate.csv', 120),
        ];
        sync.currentIndex = 2;
        sync.meterSync = const MeterSyncResult(MeterSyncOutcome.sent,
            MeterEvent(resetUtcSeconds: 1794384000, jase: 12, matt: 9, distanceM: 48211, waterS: 15300, flags: 1));
        sync.meterComparison = MeterComparison(
            const MeterReading(catchesByAngler: {'Jase': 11, 'Matt': 9}, distanceM: 48000, onWater: Duration(seconds: 15200), trips: 2),
            sync.meterSync!.logger!);
        sync.summary = SyncSummary()
          ..files = 3
          ..alreadyHad = 1
          ..newPoints = 5210
          ..newCatches = 7
          ..undatedCatches = 2
          ..failures.add('gps20261111.csv: CRC mismatch');
        sync.show(p);
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump(const Duration(milliseconds: 600));
        expect(_overflows(tester), isEmpty, reason: 'phase ${p.name}');
      }
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => repo.db.close());
    });

    sweep('trip meter and totals cards fit at font ×$scale', (tester) async {
      _useS21(tester);
      const big = MeterReading(
        catchesByAngler: {'Jase': 1284, 'Matt': 977},
        distanceM: 12873450,
        onWater: Duration(hours: 1287, minutes: 59),
        trips: 1342,
      );
      const loggerBig = MeterEvent(
          resetUtcSeconds: 1794384000, jase: 1284, matt: 977, distanceM: 12873450, waterS: 4636740, flags: 3);
      for (final b in Brightness.values) {
        await tester.pumpWidget(_app(
          AppServices(
              repo: Repository(_NoDb(), logDir: Directory.systemTemp),
              httpClient: MockClient((_) async => http.Response('', 500))),
          Scaffold(
            body: ListView(children: [
              TripMeterCard(reading: big, since: DateTime.utc(2026, 9, 30, 21, 45), resetQueued: true, onReset: () {}),
              const TripMeterCard(reading: MeterReading.zero, since: null, resetQueued: false, onReset: _noop),
              TotalsCard(reading: big, firstTrip: DateTime.utc(2025, 12, 28)),
              const TotalsCard(reading: MeterReading.zero),
              for (final o in MeterSyncOutcome.values)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: LoggerMeterPanel(
                    result: MeterSyncResult(o, o == MeterSyncOutcome.failed || o == MeterSyncOutcome.unsupported ? null : loggerBig,
                        queued: true, error: 'The logger can\'t read or write its SD card'),
                    comparison: o == MeterSyncOutcome.failed || o == MeterSyncOutcome.unsupported
                        ? null
                        : MeterComparison(o == MeterSyncOutcome.inStep ? big : MeterReading.zero, loggerBig),
                  ),
                ),
            ]),
          ),
          scale,
          b: b,
        ));
        await tester.pump();
        expect(_overflows(tester), isEmpty, reason: b.name);
        for (var i = 0; i < 4; i++) {
          await tester.drag(find.byType(ListView), const Offset(0, -500));
          await tester.pump(const Duration(milliseconds: 300));
          expect(_overflows(tester), isEmpty, reason: '${b.name}, scrolled');
        }
      }
    });

    sweep('resetting from home works and its dialog fits at font ×$scale', (tester) async {
      _useS21(tester);
      final tmp = Directory.systemTemp.createTempSync('catchlog');
      final repo = await tester.runAsync(() => _repoWithFixtures(tmp));
      final services = AppServices(repo: repo!, httpClient: MockClient((_) async => http.Response('', 500)));
      Future<void> settle() async {
        for (var i = 0; i < 4; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
          await tester.pump(const Duration(milliseconds: 150));
        }
      }

      await tester.pumpWidget(_app(services, const HomeScreen(), scale));
      await settle();
      expect(find.textContaining('TRIP METER', findRichText: true), findsOneWidget);
      expect(find.text('Since the first trip'), findsOneWidget);
      await tester.tap(find.text('Reset'));
      await settle();
      expect(find.text('Reset the trip meter?'), findsOneWidget);
      expect(_overflows(tester), isEmpty, reason: 'dialog');
      await tester.tap(find.widgetWithText(FilledButton, 'Reset'));
      await settle();
      expect(await tester.runAsync(() => repo.pendingMeterReset()), isNotNull);
      // The home screen reloads from the database in the background.
      for (var i = 0; i < 40 && !tester.any(find.textContaining('resets at the next sync')); i++) {
        await settle();
      }
      expect(find.textContaining('resets at the next sync'), findsOneWidget);
      expect(find.text('Since the first trip'), findsNothing);
      expect(_overflows(tester), isEmpty, reason: 'after the reset');
      await tester.runAsync(() => repo.db.close());
    });

    sweep('trip stats and catch cards fit at font ×$scale', (tester) async {
      _useS21(tester);
      final tmp = Directory.systemTemp.createTempSync('catchlog');
      final repo = await tester.runAsync(() => _repoWithFixtures(tmp));
      final services = AppServices(repo: repo!, httpClient: MockClient((_) async => http.Response('', 500)));
      final trips = await tester.runAsync(() => repo.trips());
      final data = await tester.runAsync(() => repo.tripData(trips!.first.id));
      final catches = data!.catches;
      final at = catches.first.time!;
      final cond = CatchConditions(
        at: at,
        sun: sunTimes(at, -33.86, 151.27),
        sunAltitudeDeg: 30,
        moon: moonIllumination(at),
        windKn: 14.6,
        windDirDeg: 225,
        gustKn: 22.4,
        waveM: 1.42,
        wavePeriodS: 9.8,
        waveDirDeg: 160,
        seaTempC: 19.6,
        pressureHpa: 1013.4,
        pressureTrend: PressureTrend.falling,
        airTempC: 22.3,
      );
      await tester.pumpWidget(_app(
        services,
        Scaffold(
          body: ListView(padding: const EdgeInsets.all(16), children: [
            const StatGrid(children: [
              StatTile(label: 'Duration', value: '4 h 32 m', icon: Icons.schedule_rounded),
              StatTile(label: 'Distance', value: '23.4 km', icon: Icons.route_rounded),
              StatTile(label: 'Moving', value: '2 h 05 m', icon: Icons.directions_boat_rounded),
              StatTile(label: 'Max speed', value: '38.2 km/h', icon: Icons.speed_rounded),
              StatTile(label: 'Sunrise · sunset', value: '5:49a · 7:30p', icon: Icons.wb_twilight_rounded),
              StatTile(label: 'Moon', value: '🌒 12%', icon: Icons.dark_mode_rounded),
            ]),
            for (final c in catches.where((c) => c.time != null)) Center(child: MomentBanner(data: data, c: c)),
            for (final (i, c) in catches.indexed)
              CatchCard(
                catchItem: c,
                number: i + 1,
                tripStartMs: data.trip.stats.startMs,
                photos: const [],
                conditions: i.isEven ? cond : null,
                conditionsLoading: false,
                conditionsError: i == 1 ? 'SocketException' : null,
                onRetryConditions: () {},
              ),
          ]),
        ),
        scale,
      ));
      await tester.pump();
      expect(_overflows(tester), isEmpty);
      for (var i = 0; i < 8; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -500));
        await tester.pump(const Duration(milliseconds: 300));
        expect(_overflows(tester), isEmpty);
      }
      await tester.runAsync(() => repo.db.close());
    });

    sweep('erasing all data from home works and its dialogs fit at font ×$scale', (tester) async {
      _useS21(tester);
      final tmp = Directory.systemTemp.createTempSync('catchlog');
      final repo = await tester.runAsync(() => _repoWithFixtures(tmp));
      final services = AppServices(repo: repo!, httpClient: MockClient((_) async => http.Response('', 500)));
      Future<void> settle() async {
        for (var i = 0; i < 4; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
          await tester.pump(const Duration(milliseconds: 150));
        }
      }

      await tester.pumpWidget(_app(services, const HomeScreen(), scale));
      await settle();
      await tester.tap(find.byType(PopupMenuButton<String>));
      await settle();
      expect(find.text('Erase logger files…'), findsOneWidget);
      expect(_overflows(tester), isEmpty, reason: 'menu');
      await tester.tap(find.text('Erase all data…'));
      await settle();
      expect(find.text('Erase all data?'), findsOneWidget);
      expect(find.textContaining('3 trips'), findsOneWidget);
      expect(_overflows(tester), isEmpty, reason: 'what goes');
      await tester.tap(find.text('Continue'));
      await settle();
      final erase = find.widgetWithText(FilledButton, 'Erase');
      expect(tester.widget<FilledButton>(erase).onPressed, isNull); // not until ERASE is typed
      await tester.enterText(find.byType(TextField), 'eras');
      await tester.pump();
      expect(tester.widget<FilledButton>(erase).onPressed, isNull);
      await tester.enterText(find.byType(TextField), 'erase');
      await tester.pump();
      expect(_overflows(tester), isEmpty, reason: 'type ERASE');
      await tester.tap(erase);
      for (var i = 0; i < 40 && !tester.any(find.text('This phone is erased')); i++) {
        await settle();
      }
      expect(find.text('This phone is erased'), findsOneWidget);
      expect(_overflows(tester), isEmpty, reason: 'offer to erase the logger');
      expect(await tester.runAsync(() => repo.trips()), isEmpty);
      await tester.tap(find.text('Not now'));
      for (var i = 0; i < 40 && !tester.any(find.text('Try it with sample trips')); i++) {
        await settle();
      }
      // Back to the first-run empty state.
      expect(find.text('No trips yet'), findsOneWidget);
      expect(find.text('Try it with sample trips'), findsOneWidget);
      expect(_overflows(tester), isEmpty, reason: 'empty home');
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => repo.db.close());
    });

    sweep('every erase logger state fits at font ×$scale', (tester) async {
      _useS21(tester);
      final c = _ShownErase()..version = 2;
      final services = AppServices(repo: Repository(_NoDb(), logDir: Directory.systemTemp), httpClient: MockClient((_) async => http.Response('', 500)));
      await tester.pumpWidget(_app(services, EraseLoggerScreen(controller: c), scale));
      for (final files in [
        const <FileEvent>[],
        const [
          FileEvent(48211, 'gps20261108.csv'),
          FileEvent(683, 'gps20261109.csv'),
          FileEvent(120344, 'gps20261110.csv'),
          FileEvent(9000, 'gps20261111.csv'),
          FileEvent(120, 'gpsnodate.csv'),
        ],
      ]) {
        c.unsynced = files;
        c.error = 'The logger is busy sending another file. Nothing was erased.';
        c.phoneResetAt = DateTime.utc(2026, 11, 11, 8);
        const meter = MeterEvent(resetUtcSeconds: 1794384000, jase: 0, matt: 0, distanceM: 0, waterS: 0, flags: 0);
        for (final p in EraseLoggerPhase.values) {
          c.result = const LoggerEraseResult(deletedFiles: 12, meter: meter);
          c.remaining = [];
          c.show(p);
          await tester.pump(const Duration(milliseconds: 300));
          expect(_overflows(tester), isEmpty, reason: '${p.name}, ${files.length} files');
        }
        // Done, but some files wouldn't delete and /trip.txt wasn't saved.
        c.result = const LoggerEraseResult(deletedFiles: 9, failedFiles: 3, resetNotSaved: true, meter: meter);
        c.remaining = files.take(2).toList();
        c.show(EraseLoggerPhase.done);
        await tester.pump(const Duration(milliseconds: 300));
        expect(_overflows(tester), isEmpty, reason: 'partly erased, ${files.length} files');
      }
      await tester.pumpWidget(const SizedBox());
    });
  }

}
