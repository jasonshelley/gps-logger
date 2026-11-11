#pragma once
// Trip meter, like a car's: counts from a reset time until the next reset.
//
// Counts, since the reset time (UTC):
//   - catches per angler (catch rows at or after the reset time)
//   - distance along the logged track, in metres
//   - time on the water, in seconds
// Distance and time come from pairs of consecutive track points that are both
// at or after the reset time and no more than SEGMENT_GAP_S apart. So time on
// the water is time spent logging with a good fix, the same span the GPX track
// segments cover. Gaps where the logger was off or had no fix don't count.
//
// The reset time is kept in /trip.txt on the card. At boot, and after a reset,
// the meter is rebuilt from every log file dated on or after the reset's local
// date, in /uploaded and in the root folder. After that it's kept up to date
// as points and catches are logged. Only the phone app resets it (BLE METER_RESET).

#include <stdint.h>
#include <time.h>

#include "track_logger.h"

namespace trip {

struct Meter {
  time_t resetUtc = 0;   // 0 = never reset: counts every log on the card
  uint32_t jase = 0, matt = 0;
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
void onTrackPoint(time_t utc, double lat, double lng);
void onCatch(Angler who, time_t utc);  // utc 0 if the clock isn't set yet (still counts)

enum class ResetResult { Applied, Unchanged, SaveFailed };

// Makes the meter count from 't' (UTC seconds). Sending the same 't' again
// changes nothing. The caller must flush the log buffer first, so the rebuild sees every row.
ResetResult reset(time_t t);

const Meter& meter();

}  // namespace trip
