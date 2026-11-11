#pragma once
// GPS receiver on UART1, parsed with TinyGPSPlusPlus.

#include <TinyGPSPlus.h>
#include <time.h>

// A fix that passed the quality filter (valid location, HDOP <= MAX_HDOP).
struct GoodFix {
  bool valid = false;
  double lat = 0, lng = 0;
  double altM = 0, speedKmh = 0, courseDeg = 0, hdop = 0;
  bool altValid = false, speedValid = false, courseValid = false;
  uint8_t satsTracked = 0, satsVisible = 0;
  int quality = 0;
  char mode = 'N';
  time_t utc = 0;          // 0 if the clock wasn't set when this fix arrived
  uint32_t atMs = 0;       // millis() when it arrived; 0 if loaded from the card
};

namespace gpsrx {

void begin();

// Reads all waiting bytes. Returns true when a new location sentence completed.
bool poll(uint32_t nowMs);

TinyGPSPlus& parser();

// HDOP, or 100 if none has arrived.
double hdop();
bool commsOk(uint32_t nowMs);
// A good fix arrived within LOCK_TIMEOUT_MS.
bool hasLock(uint32_t nowMs);

// Builds a GoodFix from the parser if the current location passes the filter.
bool currentGoodFix(GoodFix& out, uint32_t nowMs);

// The most recent good fix (from this session, or seeded from today's file at boot).
const GoodFix& lastGoodFix();
void setLastGoodFix(const GoodFix& f);

}  // namespace gpsrx
