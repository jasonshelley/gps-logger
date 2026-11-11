import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../core/geo.dart';
import '../core/log_csv.dart';
import '../core/meter.dart';
import '../core/move_meter.dart';
import '../core/trips.dart';

class Trip {
  const Trip(this.id, this.stats);
  final int id;
  final TripStats stats;
}

class TripData {
  TripData(this.trip, this.points, this.catches);
  final Trip trip;

  /// Every point, as logged.
  final List<TrackPoint> points;
  final List<StoredCatch> catches;

  /// The route to draw and replay: jitter pinned, poor fixes left out.
  late final List<TrackPoint> track = displayTrack(points);
}

/// A catch as stored, with its database id (used to key photos and conditions).
class StoredCatch {
  const StoredCatch(this.id, this.event);
  final int id;
  final CatchEvent event;
  String get angler => event.angler;
  DateTime? get time => event.time;
}

class ImportResult {
  const ImportResult({
    required this.alreadyHad,
    required this.newPoints,
    required this.newCatches,
    required this.undatedCatches,
    required this.badLines,
    required this.tripIds,
  });

  /// The exact same file (name and CRC) was imported before.
  final bool alreadyHad;
  final int newPoints;
  final int newCatches;
  final int undatedCatches;
  final int badLines;

  /// Trips that now contain this file's records.
  final Set<int> tripIds;
}

/// Everything the app stores. Local only: SQLite plus the raw CSV files.
class Repository {
  Repository(this.db, {required this.logDir});

  final Database db;

  /// Where raw CSV files are kept, exactly as received.
  final Directory logDir;

  final _changes = <void Function()>[];
  void addListener(void Function() f) => _changes.add(f);
  void removeListener(void Function() f) => _changes.remove(f);
  void _notify() {
    for (final f in List.of(_changes)) {
      f();
    }
  }

  Future<bool> hasFile(String name, int crc) async =>
      (await db.query('files', where: 'name = ? AND crc = ?', whereArgs: [name, crc], limit: 1))
          .isNotEmpty;

  /// Stores a file received from the logger and rebuilds the affected trips.
  /// Importing the same file twice is harmless.
  ///
  /// [shift] moves every timestamp; the built-in sample trips use it so they
  /// can never collide with real logs.
  Future<ImportResult> importLog(String name, Uint8List bytes, int crc, {Duration shift = Duration.zero}) async {
    if (await hasFile(name, crc)) {
      return const ImportResult(
          alreadyHad: true, newPoints: 0, newCatches: 0, undatedCatches: 0, badLines: 0, tripIds: {});
    }
    // Parse first: a file we can't read is never stored or confirmed.
    var parsed = parseLogCsv(latin1.decode(bytes));
    if (shift != Duration.zero) parsed = _shifted(parsed, shift);

    await logDir.create(recursive: true);
    final base = p.basenameWithoutExtension(name);
    final file = File(p.join(logDir.path, '$base-${crc.toRadixString(16).padLeft(8, '0')}.csv'));
    await file.writeAsBytes(bytes, flush: true);

    var newPoints = 0, newCatches = 0;
    await db.transaction((txn) async {
      final fileId = await txn.insert('files', {
        'name': name,
        'crc': crc,
        'size': bytes.length,
        'received_at': DateTime.now().millisecondsSinceEpoch,
        'path': file.path,
        'points': parsed.points.length,
        'catches': parsed.catches.length,
      });
      final before = Sqflite.firstIntValue(await txn.rawQuery('SELECT COUNT(*) FROM points')) ?? 0;
      final beforeC = Sqflite.firstIntValue(await txn.rawQuery('SELECT COUNT(*) FROM catches')) ?? 0;
      final batch = txn.batch();
      for (final pt in parsed.points) {
        batch.insert(
            'points',
            {
              't': pt.t,
              'lat': pt.lat,
              'lon': pt.lon,
              'alt': pt.altM,
              'speed': pt.speedKmh,
              'course': pt.courseDeg,
              'hdop': pt.hdop,
              'sats': pt.sats,
              'file_id': fileId,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      for (final c in parsed.catches) {
        batch.insert(
            'catches',
            {
              't': c.t,
              'angler': c.angler,
              'lat': c.lat,
              'lon': c.lon,
              'alt': c.altM,
              'fix_age': c.fixAgeS,
              'file_id': fileId,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await batch.commit(noResult: true);
      newPoints = (Sqflite.firstIntValue(await txn.rawQuery('SELECT COUNT(*) FROM points')) ?? 0) - before;
      newCatches = (Sqflite.firstIntValue(await txn.rawQuery('SELECT COUNT(*) FROM catches')) ?? 0) - beforeC;
    });

    final times = [
      ...parsed.points.map((e) => e.t),
      ...parsed.catches.map((e) => e.t).whereType<int>(),
    ];
    final tripIds = await rebuildTrips();
    final touched = <int>{};
    if (times.isNotEmpty) {
      final trips = await this.trips();
      for (final t in times) {
        for (final trip in trips) {
          if (t >= trip.stats.startMs && t <= trip.stats.endMs) {
            touched.add(trip.id);
            break;
          }
        }
      }
    }
    assert(tripIds.containsAll(touched));
    _notify();
    return ImportResult(
      alreadyHad: false,
      newPoints: newPoints,
      newCatches: newCatches,
      undatedCatches: parsed.undatedCatches,
      badLines: parsed.badLines,
      tripIds: touched,
    );
  }

  static ParsedLog _shifted(ParsedLog l, Duration d) => ParsedLog(
        points: [
          for (final p in l.points)
            TrackPoint(
                time: p.time.add(d),
                lat: p.lat,
                lon: p.lon,
                altM: p.altM,
                speedKmh: p.speedKmh,
                courseDeg: p.courseDeg,
                hdop: p.hdop,
                sats: p.sats)
        ],
        catches: [
          for (final c in l.catches)
            CatchEvent(
                angler: c.angler,
                time: c.time?.add(d),
                lat: c.lat,
                lon: c.lon,
                altM: c.altM,
                fixAgeS: c.fixAgeS)
        ],
        badLines: l.badLines,
      );

  static const samplePrefix = 'sample-';

  Future<bool> hasSamples() async => (await db.query('files',
          where: 'name LIKE ?', whereArgs: ['$samplePrefix%'], limit: 1))
      .isNotEmpty;

  /// Deletes the sample trips and nothing else: their points, catches,
  /// files and cached conditions. Real trips, the trip meter's reset and
  /// settings are kept.
  Future<void> removeSamples() async {
    final files = await db.query('files', where: 'name LIKE ?', whereArgs: ['$samplePrefix%']);
    await db.transaction((txn) async {
      for (final f in files) {
        await txn.delete('points', where: 'file_id = ?', whereArgs: [f['id']]);
        await txn.delete('catches', where: 'file_id = ?', whereArgs: [f['id']]);
        await txn.delete('files', where: 'id = ?', whereArgs: [f['id']]);
      }
    });
    for (final f in files) {
      final path = f['path'] as String?;
      if (path != null) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
    }
    await rebuildTrips();
    // Conditions cached for trips that no longer exist.
    await db.delete('trip_conditions', where: 'trip_id NOT IN (SELECT id FROM trips)');
    _previewCache.clear();
    _notify();
  }

  /// Settings that are data rather than preferences: "Erase all data"
  /// removes these and keeps every other setting.
  static const _dataSettings = [_meterResetKey, _meterPendingKey];

  /// Deletes everything synced or added to this phone: trips (real and
  /// sample), points, catches, received files and their copies on disk,
  /// cached conditions, the trip meter's reset and any reset still queued for
  /// the logger. The app is left as it was on first run. Other settings are
  /// kept. Photos stay in the gallery; nothing is sent to the logger.
  Future<void> eraseAll() async {
    await db.transaction((txn) async {
      for (final t in ['trip_conditions', 'trips', 'catches', 'points', 'files']) {
        await txn.delete(t);
      }
      await txn.delete('settings',
          where: 'key IN (${List.filled(_dataSettings.length, '?').join(', ')})', whereArgs: _dataSettings);
    });
    try {
      if (await logDir.exists()) await logDir.delete(recursive: true);
    } catch (_) {
      // A file we can't delete is harmless: nothing refers to it any more.
    }
    _previewCache.clear();
    _notify();
  }

  final _previewCache = <String, List<(double, double)>>{};

  /// Up to [maxPoints] evenly spaced route points, for the list thumbnails:
  /// the route as the map draws it, so jitter isn't scaled up into a line.
  /// A trip that never moved gives a single point.
  Future<List<(double, double)>> routePreview(Trip t, {int maxPoints = 90}) async {
    final key = '${t.id}-${t.stats.endMs}-${t.stats.pointCount}';
    final hit = _previewCache[key];
    if (hit != null) return hit;
    final track = displayTrack(await _pointsBetween(t.stats.startMs, t.stats.endMs));
    final pts = <(double, double)>[];
    for (final p in track) {
      if (pts.isEmpty || pts.last != (p.lat, p.lon)) pts.add((p.lat, p.lon));
    }
    if (t.stats.distanceM == 0 && pts.length > 1) pts.removeRange(1, pts.length);
    final step = (pts.length / maxPoints).ceil().clamp(1, 1 << 30);
    final out = <(double, double)>[
      for (var i = 0; i < pts.length; i += step) pts[i],
      if (pts.isNotEmpty && (pts.length - 1) % step != 0) pts.last,
    ];
    _previewCache[key] = out;
    return out;
  }

  Future<void> markConfirmed(String name, int crc) async {
    await db.update('files', {'confirmed_at': DateTime.now().millisecondsSinceEpoch},
        where: 'name = ? AND crc = ?', whereArgs: [name, crc]);
  }

  /// Recomputes the trips table from all points and catches. Trips whose time
  /// span is unchanged are kept as they are. Returns the ids of all trips.
  Future<Set<int>> rebuildTrips() async {
    final rows = await db.rawQuery(
        'SELECT t FROM points UNION ALL SELECT t FROM catches WHERE t IS NOT NULL ORDER BY t');
    final windows = splitIntoTrips([for (final r in rows) r['t'] as int]);
    final existing = {
      for (final r in await db.query('trips', columns: ['id', 'end_t'])) r['id'] as int: r['end_t'] as int
    };
    final keep = <int>{};
    final batch = db.batch();
    for (final w in windows) {
      keep.add(w.startMs);
      if (existing[w.startMs] == w.endMs) {
        // Same span. Re-check the counts cheaply in case a catch was added inside.
        final n = Sqflite.firstIntValue(await db.rawQuery(
                'SELECT COUNT(*) FROM points WHERE t BETWEEN ? AND ?', [w.startMs, w.endMs])) ??
            0;
        // A trip from before schema version 3 has old-rule figures: recompute it.
        final stored = Sqflite.firstIntValue(await db.rawQuery(
                'SELECT points FROM trips WHERE id = ? AND water_s IS NOT NULL', [w.startMs])) ??
            -1;
        final storedCatches = (await db.rawQuery('SELECT catches FROM trips WHERE id = ?', [w.startMs]))
            .first['catches'] as String;
        final c = Sqflite.firstIntValue(await db.rawQuery(
                'SELECT COUNT(*) FROM catches WHERE t BETWEEN ? AND ?', [w.startMs, w.endMs])) ??
            0;
        final storedC = (jsonDecode(storedCatches) as Map).values.fold<int>(0, (a, b) => a + (b as int));
        if (n == stored && c == storedC) continue;
      }
      final pts = await _pointsBetween(w.startMs, w.endMs);
      final cs = await _catchesBetween(w.startMs, w.endMs);
      final s = computeTripStats(pts, [for (final c in cs) c.event]);
      batch.insert('trips', _tripRow(w.startMs, s), conflictAlgorithm: ConflictAlgorithm.replace);
    }
    for (final id in existing.keys) {
      if (!keep.contains(id)) batch.delete('trips', where: 'id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
    return keep;
  }

  /// Recomputes trips stored before the movement rule (schema version 3),
  /// once. Cheap when there's nothing to do.
  Future<void> upgradeTrips() async {
    final stale = Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM trips WHERE water_s IS NULL')) ??
        0;
    if (stale == 0) return;
    await rebuildTrips();
    _notify();
  }

  Map<String, Object?> _tripRow(int id, TripStats s) => {
        'id': id,
        'end_t': s.endMs,
        'distance_m': s.distanceM,
        'moving_s': 0,
        'water_s': s.waterS,
        'max_speed': s.maxSpeedKmh,
        'points': s.pointCount,
        'catches': jsonEncode(s.catchesByAngler),
        'min_lat': s.bounds?.minLat,
        'min_lon': s.bounds?.minLon,
        'max_lat': s.bounds?.maxLat,
        'max_lon': s.bounds?.maxLon,
      };

  Trip _tripFromRow(Map<String, Object?> r) {
    final b = r['min_lat'] == null
        ? null
        : GeoBounds(r['min_lat'] as double, r['min_lon'] as double, r['max_lat'] as double,
            r['max_lon'] as double);
    return Trip(
      r['id'] as int,
      TripStats(
        startMs: r['id'] as int,
        endMs: r['end_t'] as int,
        distanceM: (r['distance_m'] as num).toDouble(),
        waterS: (r['water_s'] as int?) ?? 0,
        maxSpeedKmh: (r['max_speed'] as num?)?.toDouble(),
        pointCount: r['points'] as int,
        catchesByAngler: (jsonDecode(r['catches'] as String) as Map).cast<String, int>(),
        bounds: b,
      ),
    );
  }

  /// All trips, newest first.
  Future<List<Trip>> trips() async =>
      [for (final r in await db.query('trips', orderBy: 'id DESC')) _tripFromRow(r)];

  Future<Trip?> trip(int id) async {
    final r = await db.query('trips', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : _tripFromRow(r.first);
  }

  Future<TripData?> tripData(int id) async {
    final t = await trip(id);
    if (t == null) return null;
    return TripData(t, await _pointsBetween(t.stats.startMs, t.stats.endMs),
        await _catchesBetween(t.stats.startMs, t.stats.endMs));
  }

  /// Catches the logger made before it knew the date. They can't be placed in a trip.
  Future<List<StoredCatch>> undatedCatches() async =>
      [for (final r in await db.query('catches', where: 't IS NULL', orderBy: 'id')) _catchFromRow(r)];

  Future<int> fileCount() async =>
      Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM files')) ?? 0;

  Future<DateTime?> lastSync() async {
    final v = Sqflite.firstIntValue(await db.rawQuery('SELECT MAX(received_at) FROM files'));
    return v == null ? null : DateTime.fromMillisecondsSinceEpoch(v);
  }

  // --- Trip meter ---------------------------------------------------------
  //
  // Like a car's trip meter: catches, distance and time on the water since
  // the last reset. The reset time (UTC) lives here, and the meter is worked
  // out from the synced data, so a reset works with no logger in reach. The
  // logger keeps its own copy of the meter for its screen; a reset made on
  // the phone is queued and sent at the next sync, with this same time.

  static const _meterResetKey = 'meter_reset_ms';
  static const _meterPendingKey = 'meter_reset_pending_ms';

  Future<String?> _setting(String key) async {
    final r = await db.query('settings', where: 'key = ?', whereArgs: [key], limit: 1);
    return r.isEmpty ? null : r.first['value'] as String;
  }

  Future<void> _setSetting(DatabaseExecutor ex, String key, String? value) async {
    if (value == null) {
      await ex.delete('settings', where: 'key = ?', whereArgs: [key]);
    } else {
      await ex.insert('settings', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  DateTime? _utc(String? ms) =>
      ms == null ? null : DateTime.fromMillisecondsSinceEpoch(int.parse(ms), isUtc: true);

  /// When the meter was last reset, or null if it never has been (it then
  /// counts everything).
  Future<DateTime?> meterResetAt() async => _utc(await _setting(_meterResetKey));

  /// A reset made on the phone that the logger hasn't been told about yet.
  Future<DateTime?> pendingMeterReset() async => _utc(await _setting(_meterPendingKey));

  /// Resets the meter to zero now (or at [at]) and queues the reset for the logger.
  Future<DateTime> resetMeter({DateTime? at}) async {
    // Whole seconds: the logger's clock and CSV times have no milliseconds.
    final ms = ((at ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000) * 1000;
    await db.transaction((txn) async {
      await _setSetting(txn, _meterResetKey, '$ms');
      await _setSetting(txn, _meterPendingKey, '$ms');
    });
    _notify();
    return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }

  /// Takes the logger's reset time when the phone has none of its own (after
  /// a reinstall, say). Nothing is queued: the logger already has it.
  Future<void> adoptMeterReset(DateTime at) async {
    await _setSetting(db, _meterResetKey, '${at.millisecondsSinceEpoch}');
    _notify();
  }

  /// After the logger erased its files: its trip meter counts from [at] (its
  /// clock), which becomes the phone's too, replacing any queued reset. If
  /// the logger had no GPS time ([at] is null), the phone counts from now and
  /// tells the logger at the next sync.
  Future<DateTime> meterResetByLogger(DateTime? at) async {
    if (at == null) return resetMeter();
    await db.transaction((txn) async {
      await _setSetting(txn, _meterResetKey, '${at.millisecondsSinceEpoch}');
      await _setSetting(txn, _meterPendingKey, null);
    });
    _notify();
    return at;
  }

  /// Called once the logger has accepted the reset sent at [sent]. A newer
  /// reset made in the meantime stays queued.
  Future<void> meterResetDelivered(DateTime sent) async {
    final pending = await pendingMeterReset();
    if (pending != null && pending.millisecondsSinceEpoch == sent.millisecondsSinceEpoch) {
      await _setSetting(db, _meterPendingKey, null);
      _notify();
    }
  }

  /// The trip meter: everything since the last reset. A trip under way at the
  /// reset counts only from the reset on.
  Future<MeterReading> meter() async {
    final since = (await meterResetAt())?.millisecondsSinceEpoch;
    final all = await trips();
    if (since == null) return sumTrips(all.map((t) => t.stats));
    final parts = <TripStats>[];
    for (final t in all) {
      if (t.stats.endMs < since) continue;
      if (t.stats.startMs >= since) {
        parts.add(t.stats);
      } else {
        final pts = await _pointsBetween(since, t.stats.endMs);
        final cs = await _catchesBetween(since, t.stats.endMs);
        parts.add(computeTripStats(pts, [for (final c in cs) c.event]));
      }
    }
    return sumTrips(parts);
  }

  /// All-time totals, including catches made before the logger had the time.
  Future<MeterReading> totals() async {
    final byAngler = {
      for (final r in await db.rawQuery('SELECT angler, COUNT(*) AS n FROM catches GROUP BY angler'))
        r['angler'] as String: r['n'] as int
    };
    return sumTrips((await trips()).map((t) => t.stats), catchesByAngler: byAngler);
  }

  Future<List<TrackPoint>> _pointsBetween(int a, int b) async => [
        for (final r in await db.query('points', where: 't BETWEEN ? AND ?', whereArgs: [a, b], orderBy: 't'))
          TrackPoint(
            time: DateTime.fromMillisecondsSinceEpoch(r['t'] as int, isUtc: true),
            lat: r['lat'] as double,
            lon: r['lon'] as double,
            altM: (r['alt'] as num?)?.toDouble(),
            speedKmh: (r['speed'] as num?)?.toDouble(),
            courseDeg: (r['course'] as num?)?.toDouble(),
            hdop: (r['hdop'] as num?)?.toDouble(),
            sats: r['sats'] as int?,
          )
      ];

  Future<List<StoredCatch>> _catchesBetween(int a, int b) async => [
        for (final r in await db.query('catches', where: 't BETWEEN ? AND ?', whereArgs: [a, b], orderBy: 't'))
          _catchFromRow(r)
      ];

  StoredCatch _catchFromRow(Map<String, Object?> r) => StoredCatch(
        r['id'] as int,
        CatchEvent(
          angler: r['angler'] as String,
          time: r['t'] == null ? null : DateTime.fromMillisecondsSinceEpoch(r['t'] as int, isUtc: true),
          lat: (r['lat'] as num?)?.toDouble(),
          lon: (r['lon'] as num?)?.toDouble(),
          altM: (r['alt'] as num?)?.toDouble(),
          fixAgeS: r['fix_age'] as int?,
        ),
      );

  // ---- Conditions cache ----

  Future<Map<String, Object?>?> cachedConditions(int tripId) async {
    final r = await db.query('trip_conditions', where: 'trip_id = ?', whereArgs: [tripId]);
    return r.isEmpty ? null : r.first;
  }

  Future<void> saveConditions(int tripId, double lat, double lon, String? weather, String? marine) async {
    await db.insert(
        'trip_conditions',
        {
          'trip_id': tripId,
          'fetched_at': DateTime.now().millisecondsSinceEpoch,
          'lat': lat,
          'lon': lon,
          'weather': weather,
          'marine': marine,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
