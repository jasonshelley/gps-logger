#include "track_logger.h"

#include <Arduino.h>
#include <SD.h>

#include "clock.h"
#include "config.h"
#include "log_reader.h"
#include "move_meter.h"
#include "storage.h"
#include "trip_meter.h"

namespace tracklog {

static const char* kHeader =
    "type,time_utc,lat,lon,alt_m,speed_kmh,course_deg,hdop,sats_tracked,sats_visible,"
    "fix_quality,fix_mode,fix_age_s,comment\n";

// A catch made before the GPS has given us the date goes in this file.
static const char* kNoDate = "nodate";

struct Row {
  char day[9];  // local YYYYMMDD, or "nodate"
  char text[LOG_ROW_MAX];
};

static Row s_rows[LOG_BUFFER_ROWS];
static uint32_t s_count = 0;
static uint32_t s_dropped = 0;
static bool s_lastWriteOk = true;
static uint32_t s_lastFlushMs = 0;

static DayStats s_stats;
static bool s_needRebuild = false;
// Catches made before the clock was set. They count towards the first day the clock shows.
static uint32_t s_noDateJase = 0, s_noDateMatt = 0;
static char s_noDateDay[9] = "";

static_assert(MAX_HDOP == movemeter::kMaxHdop, "the GPS filter and the movement rule must agree");

// Today's distance: the movement rule over today's logged points.
static movemeter::Meter s_dayMove;

// The log rule runs the movement rule over every good fix (not just the logged
// ones) to decide whether we're moving.
static movemeter::Meter s_detector;
static bool s_haveLogged = false;  // a point logged since boot
static uint32_t s_lastLogMs = 0;
static bool s_haveMove = false;
static uint32_t s_lastMoveMs = 0;

const char* anglerName(Angler a) { return a == Angler::Jase ? "Jase" : "Matt"; }

static void fileFor(const char* day, char* path, size_t len) {
  snprintf(path, len, "/gps%s.csv", day);
}

static void appendField(char*& p, char* end, const char* s) {
  int n = snprintf(p, end - p, "%s", s);
  if (n > 0) p += (n < end - p) ? n : (end - p - 1);
}

static void appendNum(char*& p, char* end, bool valid, double v, int decimals) {
  if (valid) {
    char tmp[24];
    snprintf(tmp, sizeof(tmp), "%.*f", decimals, v);
    appendField(p, end, tmp);
  }
}

// Builds one CSV row (with trailing newline). 'fix' may be invalid (blank position).
static void formatRow(char* out, size_t len, const char* type, time_t utc, const GoodFix& fix,
                      long ageS, const char* comment) {
  char* p = out;
  char* end = out + len - 1;  // room for '\n'
  char tmp[32];

  appendField(p, end, type);
  appendField(p, end, ",");
  if (utc) {
    clk::formatIsoUtc(utc, tmp, sizeof(tmp));
    appendField(p, end, tmp);
  }
  appendField(p, end, ",");
  appendNum(p, end, fix.valid, fix.lat, 6);
  appendField(p, end, ",");
  appendNum(p, end, fix.valid, fix.lng, 6);
  appendField(p, end, ",");
  appendNum(p, end, fix.valid && fix.altValid, fix.altM, 2);
  appendField(p, end, ",");
  appendNum(p, end, fix.valid && fix.speedValid, fix.speedKmh, 2);
  appendField(p, end, ",");
  appendNum(p, end, fix.valid && fix.courseValid, fix.courseDeg, 2);
  appendField(p, end, ",");
  appendNum(p, end, fix.valid, fix.hdop, 1);
  appendField(p, end, ",");
  appendNum(p, end, fix.valid, fix.satsTracked, 0);
  appendField(p, end, ",");
  appendNum(p, end, fix.valid, fix.satsVisible, 0);
  appendField(p, end, ",");
  appendNum(p, end, fix.valid, fix.quality, 0);
  appendField(p, end, ",");
  if (fix.valid) {
    tmp[0] = fix.mode ? fix.mode : 'N';
    tmp[1] = 0;
    appendField(p, end, tmp);
  }
  appendField(p, end, ",");
  appendNum(p, end, ageS >= 0, (double)ageS, 0);
  appendField(p, end, ",");
  appendField(p, end, comment);
  *p++ = '\n';
  *p = 0;
}

static void push(const char* day, const char* text) {
  if (s_count == LOG_BUFFER_ROWS) flush();
  if (s_count == LOG_BUFFER_ROWS) {
    // Card still failing: drop the oldest row rather than the newest.
    memmove(&s_rows[0], &s_rows[1], sizeof(Row) * (LOG_BUFFER_ROWS - 1));
    s_count--;
    s_dropped++;
  }
  Row& r = s_rows[s_count++];
  snprintf(r.day, sizeof(r.day), "%s", day);
  snprintf(r.text, sizeof(r.text), "%s", text);
}

bool flush() {
  s_lastFlushMs = millis();
  if (s_count == 0) return true;
  if (!storage::ensureMounted(millis())) {
    s_lastWriteOk = false;
    return false;
  }

  uint32_t written = 0;
  bool ok = true;
  while (written < s_count && ok) {
    // Rows for the same file are next to each other almost always; write a run at a time.
    uint32_t runEnd = written + 1;
    while (runEnd < s_count && strcmp(s_rows[runEnd].day, s_rows[written].day) == 0) runEnd++;

    char path[32];
    fileFor(s_rows[written].day, path, sizeof(path));
    File f = SD.open(path, FILE_APPEND);
    if (!f) {
      ok = false;
      break;
    }
    if (f.size() == 0 && f.print(kHeader) != strlen(kHeader)) ok = false;
    for (uint32_t i = written; i < runEnd && ok; i++) {
      size_t n = strlen(s_rows[i].text);
      if (f.write((const uint8_t*)s_rows[i].text, n) != n) ok = false;
    }
    f.close();
    if (ok) {
      Serial.printf("[log] wrote %u row(s) to %s\n", (unsigned)(runEnd - written), path);
      written = runEnd;
    }
  }

  if (written > 0) {
    memmove(&s_rows[0], &s_rows[written], sizeof(Row) * (s_count - written));
    s_count -= written;
  }
  if (!ok) storage::markFailed();
  s_lastWriteOk = ok;
  return ok;
}

// A value as the log writes it, so the live meters see exactly what a rebuild
// (or the phone app) reads back from the file.
static double asLogged(double v, int decimals) {
  char tmp[24];
  snprintf(tmp, sizeof(tmp), "%.*f", decimals, v);
  return atof(tmp);
}

// ---- Rebuilding today's numbers from the card ----

// The card's last track point, to seed the last good fix.
struct ScanState {
  bool havePrev;
  double prevLat, prevLng;
  time_t prevUtc;
};

static void scanDayFile(const char* path, ScanState& st) {
  forEachLogRow(path, [&st](char** f) {
    if (strcmp(f[COL_TYPE], "track") == 0) {
      if (!*f[COL_LAT] || !*f[COL_LON]) return;
      double lat = atof(f[COL_LAT]), lng = atof(f[COL_LON]);
      time_t t = clk::parseIsoUtc(f[COL_TIME]);
      s_stats.points++;
      if (t != 0 && *f[COL_HDOP]) {
        s_dayMove.add(t, lat, lng, atof(f[COL_HDOP]));
        s_stats.distanceM = s_dayMove.distanceM();
      }
      st.havePrev = true;
      st.prevLat = lat;
      st.prevLng = lng;
      st.prevUtc = t;
    } else if (strcmp(f[COL_TYPE], "catch") == 0) {
      if (strncmp(f[COL_COMMENT], "Jase", 4) == 0) s_stats.jase++;
      if (strncmp(f[COL_COMMENT], "Matt", 4) == 0) s_stats.matt++;
    }
  });
}

static void rebuild(const char* day) {
  s_stats = DayStats();
  snprintf(s_stats.date, sizeof(s_stats.date), "%s", day);
  s_stats.known = true;
  s_dayMove.clear();

  if (!storage::mounted()) {
    s_needRebuild = true;  // try again once the card is back
  } else {
    s_needRebuild = false;
    ScanState st = {false, 0, 0, 0};
    char path[48];
    // Earlier transfers today moved part of the day to /uploaded.
    snprintf(path, sizeof(path), UPLOADED_DIR "/gps%s.csv", day);
    scanDayFile(path, st);
    fileFor(day, path, sizeof(path));
    scanDayFile(path, st);

    // Seed the last good fix so a catch made before the first fix still has a position.
    if (st.havePrev && !gpsrx::lastGoodFix().valid) {
      GoodFix g;
      g.valid = true;
      g.lat = st.prevLat;
      g.lng = st.prevLng;
      g.utc = st.prevUtc;
      g.atMs = 0;
      gpsrx::setLastGoodFix(g);
    }
  }
  if (s_noDateJase || s_noDateMatt) {
    if (!s_noDateDay[0]) snprintf(s_noDateDay, sizeof(s_noDateDay), "%s", day);
    if (strcmp(s_noDateDay, day) == 0) {
      s_stats.jase += s_noDateJase;
      s_stats.matt += s_noDateMatt;
    }
  }
  Serial.printf("[log] today %s: %lu points, %.0f m, Jase %lu, Matt %lu%s\n", s_stats.date,
                (unsigned long)s_stats.points, s_stats.distanceM, (unsigned long)s_stats.jase,
                (unsigned long)s_stats.matt, s_needRebuild ? " (card not mounted)" : "");
}

// Makes sure s_stats is for the current local day.
static void ensureDay() {
  if (!clk::isSet()) return;
  char today[9];
  clk::localDateStamp(clk::now(), today);
  if (!s_stats.known || strcmp(today, s_stats.date) != 0) {
    flush();  // so the file includes everything buffered
    rebuild(today);
  }
}

// ---- Public ----

void begin() { s_lastFlushMs = millis(); }

// The log rule (docs/metrics.md, "Logging"). Called for every good fix.
static bool shouldLog(const GoodFix& fix, uint32_t nowMs) {
  bool moved = s_detector.add(fix.utc, fix.lat, fix.lng, fix.hdop) > 0;
  if (moved) {
    s_haveMove = true;
    s_lastMoveMs = nowMs;
  }
  if (!s_haveLogged || moved) return true;  // first point since boot, or a move
  uint32_t dt = nowMs - s_lastLogMs;
  bool moving = s_haveMove && nowMs - s_lastMoveMs < LOG_MOVING_HOLD_MS;
  if (moving && dt >= LOG_MIN_INTERVAL_MS) return true;
  return dt >= LOG_STATIONARY_INTERVAL_MS;
}

void onLocation(const GoodFix& fix, uint32_t nowMs) {
  if (!fix.valid || fix.utc == 0) return;  // track points need a date for the file name
  ensureDay();
  if (!shouldLog(fix, nowMs)) return;

  char day[9];
  clk::localDateStamp(fix.utc, day);
  char row[LOG_ROW_MAX];
  formatRow(row, sizeof(row), "track", fix.utc, fix, -1, "");
  push(day, row);

  double lat = asLogged(fix.lat, 6), lng = asLogged(fix.lng, 6), hdop = asLogged(fix.hdop, 1);
  if (strcmp(day, s_stats.date) == 0) {
    s_stats.points++;
    s_dayMove.add(fix.utc, lat, lng, hdop);
    s_stats.distanceM = s_dayMove.distanceM();
  }
  trip::onTrackPoint(fix.utc, lat, lng, hdop);
  s_haveLogged = true;
  s_lastLogMs = nowMs;
}

bool logCatch(Angler who, uint32_t nowMs) {
  ensureDay();
  GoodFix cur;
  bool fresh = gpsrx::currentGoodFix(cur, nowMs);
  const GoodFix& fix = fresh ? cur : gpsrx::lastGoodFix();
  time_t nowUtc = clk::isSet() ? clk::now() : 0;

  long ageS = -1;
  if (fresh) {
    ageS = 0;
  } else if (fix.valid) {
    if (fix.atMs) ageS = (long)((nowMs - fix.atMs) / 1000);
    else if (fix.utc && nowUtc) ageS = (long)(nowUtc - fix.utc);
  }

  char comment[16];
  snprintf(comment, sizeof(comment), "%s catch", anglerName(who));
  char row[LOG_ROW_MAX];
  formatRow(row, sizeof(row), "catch", nowUtc, fix, ageS, comment);

  char day[9];
  if (nowUtc) {
    clk::localDateStamp(nowUtc, day);
    if (who == Angler::Jase) s_stats.jase++; else s_stats.matt++;
  } else {
    snprintf(day, sizeof(day), "%s", kNoDate);
    if (who == Angler::Jase) { s_noDateJase++; s_stats.jase++; } else { s_noDateMatt++; s_stats.matt++; }
  }
  push(day, row);
  trip::onCatch(who, nowUtc);
  Serial.printf("[log] %s (fix %s, age %ld s)\n", comment,
                fresh ? "current" : (fix.valid ? "last good" : "none"), ageS);
  return flush();
}

void tick(uint32_t nowMs) {
  ensureDay();
  if (s_needRebuild && storage::mounted()) {
    flush();
    char day[9];
    snprintf(day, sizeof(day), "%s", s_stats.date);
    rebuild(day);
  }
  if (trip::needsRebuild() && storage::mounted()) {
    flush();
    trip::tick();
  }
  if (nowMs - s_lastFlushMs >= FLUSH_INTERVAL_MS) flush();
}

EraseResult eraseAllLogs() {
  EraseResult r;
  if (!storage::ensureMounted(millis())) return r;

  // Nothing here flushes, so deleting the files before dropping the buffer is
  // safe, and a card that can't be read leaves everything as it was.
  r.cardOk = storage::eraseLogFiles(r.deleted, r.failed);
  if (!r.cardOk) {
    storage::markFailed();
    return r;
  }

  // Drop what's buffered, so nothing erased is written straight back.
  s_count = 0;
  s_dropped = 0;
  s_noDateJase = s_noDateMatt = 0;
  s_noDateDay[0] = 0;
  s_dayMove.clear();
  bool known = s_stats.known;
  char date[9];
  snprintf(date, sizeof(date), "%s", s_stats.date);
  s_stats = DayStats();
  s_stats.known = known;
  snprintf(s_stats.date, sizeof(s_stats.date), "%s", date);
  s_needRebuild = false;

  r.tripSaved = trip::resetAfterErase(clk::isSet() ? clk::now() : 0) == trip::ResetResult::Applied;
  return r;
}

const DayStats& stats() { return s_stats; }
uint32_t buffered() { return s_count; }
uint32_t droppedRows() { return s_dropped; }
bool lastWriteOk() { return s_lastWriteOk; }

}  // namespace tracklog
