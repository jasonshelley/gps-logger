#pragma once
// Trip meter, like a car's: counts from a reset time until the next reset.
//
// Counts, since the reset time (UTC):
//   - catches per angler (catch rows at or after the reset time, less the
//     ones undone), matched to the anglers by name (anglers.h)
//   - distance moved, in metres
//   - time on the water, in seconds
// Distance and time follow the movement rule in docs/metrics.md (move_meter.h),
// over the track points at or after the reset time, so GPS jitter while the
// logger sits still adds nothing.
//
// The reset time is kept in /trip.txt on the card. At boot, and after a reset,
// the meter is rebuilt from every log file dated on or after the reset's local
// date, in /uploaded and in the root folder. After that it's kept up to date
// as points and catches are logged. Only the phone app resets it (BLE METER_RESET).

#include <stdint.h>
#include <time.h>

#include "config.h"

namespace trip {

struct Meter {
  time_t resetUtc = 0;   // 0 = never reset: counts every log on the card
  uint32_t catches[MAX_ANGLERS] = {};  // by angler, in button order
  double distanceM = 0;
  uint32_t waterS = 0;
  bool complete = false; // false if the card couldn't be read for the last rebuild
};

// Loads the reset time and rebuilds the meter. Call after storage::begin() and clk::begin().
void begin();

// True when a rebuild failed because the card wasn't available.
bool needsRebuild();
// Retries that rebuild once the card is back. Flush the log buffer first.
void tick();

// Live updates, called by the track logger for each row it logs.
// Pass lat, lng and hdop as written to the log, so the live meter matches a rebuild.
void onTrackPoint(time_t utc, double lat, double lng, double hdop);
void onCatch(int angler, time_t utc);  // utc 0 if the clock isn't set yet (still counts)

// The angler's most recent catch that can still be undone: one since the
// reset, not undone already, and among the last few dozen. False if none.
// 'utc' is that catch's time (0 if it had none).
bool lastCatch(int angler, time_t& utc);
// Undoes the catch lastCatch() returned (call after logging the undo row).
void onUndo(int angler);

// Rebuilds from the logs, e.g. after the anglers change. Flush the log buffer first.
void rebuildNow();

enum class ResetResult { Applied, Unchanged, SaveFailed };

// Makes the meter count from 't' (UTC seconds). Sending the same 't' again
// changes nothing. The caller must flush the log buffer first, so the rebuild sees every row.
ResetResult reset(time_t t);

// After the log files are erased: makes the meter count from 't' (0 if the
// clock isn't set) and always rebuilds, even if 't' is unchanged. Returns
// SaveFailed if /trip.txt couldn't be written; the meter is reset in memory anyway.
ResetResult resetAfterErase(time_t t);

const Meter& meter();

}  // namespace trip
