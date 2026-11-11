import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

const int schemaVersion = 2;

/// Opens (and creates or upgrades) the app's SQLite database.
/// [factory] lets tests pass the in-memory FFI factory.
Future<Database> openAppDatabase({DatabaseFactory? factory, String? path}) async {
  final f = factory ?? databaseFactory;
  final dbPath = path ?? p.join(await f.getDatabasesPath(), 'catch_log.db');
  return f.openDatabase(
    dbPath,
    options: OpenDatabaseOptions(
      version: schemaVersion,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, _) async {
        await _create(db);
        await _createSettings(db);
      },
      onUpgrade: (db, from, to) async {
        if (from < 2) await _createSettings(db);
      },
    ),
  );
}

Future<void> _create(Database db) async {
  final b = db.batch();
  // One row per file received from the logger. The same name can arrive more
  // than once (the logger appends later rows of a day it already sent), so
  // files are keyed by name and CRC.
  b.execute('''
    CREATE TABLE files (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      crc INTEGER NOT NULL,
      size INTEGER NOT NULL,
      received_at INTEGER NOT NULL,
      confirmed_at INTEGER,
      path TEXT,
      points INTEGER NOT NULL DEFAULT 0,
      catches INTEGER NOT NULL DEFAULT 0,
      UNIQUE(name, crc)
    )''');
  // Track points, keyed by time (ms since epoch, UTC). The logger never writes
  // two points in the same second, so time is unique and makes imports idempotent.
  b.execute('''
    CREATE TABLE points (
      t INTEGER PRIMARY KEY,
      lat REAL NOT NULL,
      lon REAL NOT NULL,
      alt REAL,
      speed REAL,
      course REAL,
      hdop REAL,
      sats INTEGER,
      file_id INTEGER REFERENCES files(id)
    )''');
  b.execute('''
    CREATE TABLE catches (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      t INTEGER,
      angler TEXT NOT NULL,
      lat REAL,
      lon REAL,
      alt REAL,
      fix_age INTEGER,
      file_id INTEGER REFERENCES files(id),
      UNIQUE(t, angler)
    )''');
  b.execute('CREATE INDEX catches_t ON catches(t)');
  // Derived from points and catches; rebuilt after each import.
  // id = start time in ms, so it stays stable as long as the start does.
  b.execute('''
    CREATE TABLE trips (
      id INTEGER PRIMARY KEY,
      end_t INTEGER NOT NULL,
      distance_m REAL NOT NULL,
      moving_s INTEGER NOT NULL,
      max_speed REAL,
      points INTEGER NOT NULL,
      catches TEXT NOT NULL,
      min_lat REAL, min_lon REAL, max_lat REAL, max_lon REAL
    )''');
  // Open-Meteo responses per trip, cached so a trip opens offline.
  b.execute('''
    CREATE TABLE trip_conditions (
      trip_id INTEGER PRIMARY KEY,
      fetched_at INTEGER NOT NULL,
      lat REAL NOT NULL,
      lon REAL NOT NULL,
      weather TEXT,
      marine TEXT
    )''');
  await b.commit(noResult: true);
}

/// Version 2: small key-value settings, such as the trip meter's reset time.
Future<void> _createSettings(Database db) =>
    db.execute('CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
