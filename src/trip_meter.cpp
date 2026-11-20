#include "trip_meter.h"

#include <Arduino.h>
#include <SD.h>

#include <algorithm>
#include <string>
#include <vector>

#include "anglers.h"
#include "clock.h"
#include "config.h"
#include "log_reader.h"
#include "move_meter.h"
#include "storage.h"

namespace trip {

static Meter s_meter;
static bool s_needRebuild = false;

// Distance and time on the water, from the track points since the reset (docs/metrics.md).
static movemeter::Meter s_move;

// Each angler's recent catch times since the reset, oldest first, for undo.
// Only the last kRecentMax are kept; older catches still count but can't be undone.
static const size_t kRecentMax = 50;
static std::vector<time_t> s_recent[MAX_ANGLERS];

// ---- Accumulating ----

static void addTrackPoint(time_t utc, double lat, double lng, double hdop) {
  if (utc < s_meter.resetUtc) return;  // the first point after the reset starts a segment
  s_move.add(utc, lat, lng, hdop);
  s_meter.distanceM = s_move.distanceM();
  s_meter.waterS = s_move.waterS();
}

void onTrackPoint(time_t utc, double lat, double lng, double hdop) { addTrackPoint(utc, lat, lng, hdop); }

static void addCatch(int a, time_t utc) {
  if (a < 0 || a >= MAX_ANGLERS) return;
  if (utc != 0 && utc < s_meter.resetUtc) return;
  s_meter.catches[a]++;
  s_recent[a].push_back(utc);
  if (s_recent[a].size() > kRecentMax) s_recent[a].erase(s_recent[a].begin());
}

// An undo row: removes the catch made at 'catchUtc', or the angler's latest
// catch when the undo names no time (that catch had none either).
static void addUndo(int a, time_t catchUtc) {
  if (a < 0 || a >= MAX_ANGLERS) return;
  std::vector<time_t>& r = s_recent[a];
  if (catchUtc == 0) {
    if (r.empty()) return;
    r.pop_back();
  } else {
    if (catchUtc < s_meter.resetUtc) return;  // before the reset: never counted
    auto it = std::find(r.rbegin(), r.rend(), catchUtc);
    if (it != r.rend()) r.erase(std::next(it).base());
  }
  if (s_meter.catches[a] > 0) s_meter.catches[a]--;
}

void onCatch(int angler, time_t utc) { addCatch(angler, utc); }

bool lastCatch(int angler, time_t& utc) {
  if (angler < 0 || angler >= MAX_ANGLERS || s_recent[angler].empty()) return false;
  utc = s_recent[angler].back();
  return true;
}

void onUndo(int angler) {
  time_t utc;
  if (lastCatch(angler, utc)) addUndo(angler, utc);
}

// ---- The reset file ----

static bool readResetFile(const char* path, time_t& out) {
  File f = SD.open(path, FILE_READ);
  if (!f) return false;
  char buf[48] = {0};
  f.read((uint8_t*)buf, sizeof(buf) - 1);
  f.close();
  long long v;
  if (sscanf(buf, "reset_utc=%lld", &v) != 1 || v < 0) return false;
  out = (time_t)v;
  return true;
}

static time_t loadResetTime() {
  time_t t = 0;
  if (readResetFile(TRIP_FILE, t)) return t;
  // A save interrupted between removing trip.txt and renaming trip.tmp.
  if (readResetFile(TRIP_TMP_FILE, t)) return t;
  return 0;
}

// Writes trip.tmp, then swaps it in (FAT rename can't replace a file).
static bool saveResetTime(time_t t) {
  if (!storage::mounted()) return false;
  File f = SD.open(TRIP_TMP_FILE, FILE_WRITE);
  if (!f) return false;
  char iso[24];
  clk::formatIsoUtc(t, iso, sizeof(iso));
  char buf[96];
  int n = snprintf(buf, sizeof(buf), "reset_utc=%lld\n# %s, set by the phone app\n", (long long)t, iso);
  bool ok = f.write((const uint8_t*)buf, n) == (size_t)n;
  f.close();
  if (!ok) return false;
  if (SD.exists(TRIP_FILE) && !SD.remove(TRIP_FILE)) return false;
  return SD.rename(TRIP_TMP_FILE, TRIP_FILE);
}

// ---- Rebuilding from the logs ----

// "gpsYYYYMMDD.csv" -> "YYYYMMDD"; false for other names (gpsnodate.csv has no times).
static bool dayFromName(const char* name, char* day) {
  if (strlen(name) != 15 || strncasecmp(name, "gps", 3) != 0 || strcasecmp(name + 11, ".csv") != 0) return false;
  for (int i = 0; i < 8; i++) {
    if (name[3 + i] < '0' || name[3 + i] > '9') return false;
    day[i] = name[3 + i];
  }
  day[8] = 0;
  return true;
}

static void scanFile(const char* path) {
  forEachLogRow(path, [](char** f) {
    char name[ANGLER_NAME_MAX + 2];
    if (strcmp(f[COL_TYPE], "undo") == 0) {
      // Undo rows count whatever their own time: they name the catch they undo.
      time_t catchUtc;
      if (anglers::parseUndo(f[COL_COMMENT], name, sizeof(name), catchUtc))
        addUndo(anglers::find(name), catchUtc);
      return;
    }
    if (!*f[COL_TIME]) return;  // no time: can't tell whether it's after the reset
    time_t t = clk::parseIsoUtc(f[COL_TIME]);
    if (t == 0) return;
    if (strcmp(f[COL_TYPE], "track") == 0) {
      if (!*f[COL_LAT] || !*f[COL_LON] || !*f[COL_HDOP]) return;
      addTrackPoint(t, atof(f[COL_LAT]), atof(f[COL_LON]), atof(f[COL_HDOP]));
    } else if (strcmp(f[COL_TYPE], "catch") == 0 && t >= s_meter.resetUtc) {
      if (anglers::parseCatch(f[COL_COMMENT], name, sizeof(name))) addCatch(anglers::find(name), t);
    }
  });
}

static void rebuild() {
  time_t reset = s_meter.resetUtc;
  s_meter = Meter();
  s_meter.resetUtc = reset;
  s_move.clear();
  for (auto& r : s_recent) r.clear();

  if (!storage::mounted()) {
    s_needRebuild = true;
    Serial.println("[trip] card not mounted; meter will rebuild when it's back");
    return;
  }
  s_needRebuild = false;
  uint32_t started = millis();

  // Rows go in the file for their own local date, so files dated before the
  // reset's local date can't hold anything after the reset.
  char resetDay[9] = "00000000";
  if (reset > 0) clk::localDateStamp(reset, resetDay);

  std::vector<std::string> days;
  auto collect = [&](const char* name, size_t) {
    char day[9];
    if (dayFromName(name, day) && strcmp(day, resetDay) >= 0) days.emplace_back(day);
  };
  storage::listFiles(UPLOADED_DIR, true, collect);  // may not exist yet: that's fine
  storage::listFiles("/", true, collect);
  std::sort(days.begin(), days.end());
  days.erase(std::unique(days.begin(), days.end()), days.end());

  for (const std::string& day : days) {
    char path[48];
    // A day's transferred part is older than what's still in the root folder.
    snprintf(path, sizeof(path), UPLOADED_DIR "/gps%s.csv", day.c_str());
    scanFile(path);
    snprintf(path, sizeof(path), "/gps%s.csv", day.c_str());
    scanFile(path);
  }
  s_meter.complete = true;
  Serial.printf("[trip] since %lld:", (long long)reset);
  for (int i = 0; i < anglers::count(); i++)
    Serial.printf(" %s %lu,", anglers::get(i).name, (unsigned long)s_meter.catches[i]);
  Serial.printf(" %.0f m, %lu s on the water (%u file day(s), %lu ms)\n", s_meter.distanceM,
                (unsigned long)s_meter.waterS, (unsigned)days.size(), (unsigned long)(millis() - started));
}

void rebuildNow() { rebuild(); }

// ---- Public ----

void begin() {
  s_meter.resetUtc = storage::mounted() ? loadResetTime() : 0;
  if (!storage::mounted()) {
    s_needRebuild = true;
    return;
  }
  rebuild();
}

bool needsRebuild() { return s_needRebuild; }

void tick() {
  if (s_needRebuild && storage::mounted()) {
    // The reset time couldn't be read at boot either if the card was missing.
    s_meter.resetUtc = loadResetTime();
    rebuild();
  }
}

ResetResult reset(time_t t) {
  if (t < 0) t = 0;
  if (t == s_meter.resetUtc && s_meter.complete) return ResetResult::Unchanged;
  if (t != s_meter.resetUtc && !saveResetTime(t)) {
    storage::markFailed();
    return ResetResult::SaveFailed;
  }
  s_meter.resetUtc = t;
  rebuild();
  Serial.printf("[trip] reset to %lld\n", (long long)t);
  return ResetResult::Applied;
}

ResetResult resetAfterErase(time_t t) {
  if (t < 0) t = 0;
  bool saved = saveResetTime(t);
  s_meter.resetUtc = t;
  rebuild();
  Serial.printf("[trip] reset to %lld after erasing the logs%s\n", (long long)t, saved ? "" : " (not saved)");
  if (!saved) {
    storage::markFailed();
    return ResetResult::SaveFailed;
  }
  return ResetResult::Applied;
}

const Meter& meter() { return s_meter; }

}  // namespace trip
