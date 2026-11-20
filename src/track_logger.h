#pragma once
// Track and catch logging to daily CSV files (requirements Q2, Q4-Q8).
//
// File: /gpsYYYYMMDD.csv, named by the Sydney local date of each record.
// Columns (header row first):
//   type,time_utc,lat,lon,alt_m,speed_kmh,course_deg,hdop,sats_tracked,
//   sats_visible,fix_quality,fix_mode,fix_age_s,comment
// type is "track", "catch" or "undo". fix_age_s is blank for track points. For
// a catch it's how old the fix used for the position was (0 if the fix was
// current). Catch comments are "<name> catch"; an undo row has no position and
// its comment names the catch it undoes (anglers.h).

#include <stdint.h>

#include "config.h"
#include "gps.h"

struct DayStats {
  bool known = false;          // false until the clock is set and today's file was read
  char date[9] = "";           // local YYYYMMDD
  uint32_t points = 0;         // track points today
  uint32_t catches[MAX_ANGLERS] = {};  // catches today by angler, less the ones undone
  double distanceM = 0;        // moved today (movement rule, docs/metrics.md)
};

namespace tracklog {

void begin();

// Call on every new location. Logs a track point when the log rule says so.
void onLocation(const GoodFix& fix, uint32_t nowMs);

// Records a catch for angler 'angler' (0-based, button order) now and writes it
// to the card straight away. Returns false if the card write failed (the row
// stays buffered).
bool logCatch(int angler, uint32_t nowMs);

enum class UndoResult { Undone, NothingToUndo, NotSaved };
// Undoes the angler's most recent catch since the trip reset (trip::lastCatch):
// appends an undo row naming it and writes it straight away. The catch row
// stays in the log. NotSaved: undone, but the card write failed (row buffered).
UndoResult logUndo(int angler, uint32_t nowMs);

// The anglers changed: recounts today's catches by the new names.
void anglersChanged();

// Writes buffered rows. Returns false if any couldn't be written.
bool flush();

// Periodic work: 10 s flush, day rollover, rebuilding stats once the clock is set.
void tick(uint32_t nowMs);

struct EraseResult {
  bool cardOk = false;     // false: the card wasn't available and nothing was erased
  int deleted = 0;         // log files deleted
  int failed = 0;          // log files that couldn't be deleted
  bool tripSaved = false;  // /trip.txt holds the new reset time
};

// Erases every log file (gps*.csv in / and /uploaded), drops the rows still
// buffered, zeroes today's numbers, and resets the trip meter to now (or to 0
// if the clock isn't set). readme.txt stays. Logging carries on afterwards.
EraseResult eraseAllLogs();

const DayStats& stats();
uint32_t buffered();
uint32_t droppedRows();
bool lastWriteOk();


}  // namespace tracklog
