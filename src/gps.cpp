#include "gps.h"

#include <Arduino.h>

#include "clock.h"
#include "config.h"

namespace gpsrx {

static TinyGPSPlus s_gps;
static uint32_t s_lastByteMs = 0;
static bool s_anyByte = false;
static GoodFix s_lastGood;

void begin() {
  // Serial1.begin() returns straight away; there's nothing to wait for.
  Serial1.begin(GPS_BAUD, SERIAL_8N1, PIN_GPS_RX, PIN_GPS_TX);
}

bool poll(uint32_t nowMs) {
  bool newLocation = false;
  // Bounded so a flood of bytes can't starve the rest of the loop.
  for (int n = 0; n < 512 && Serial1.available() > 0; n++) {
    s_lastByteMs = nowMs;
    s_anyByte = true;
    if (s_gps.encode((char)Serial1.read())) {
      clk::syncFromGps(s_gps);
      if (s_gps.location.isUpdated()) {
        newLocation = true;
        (void)s_gps.location.rawLat();  // clears isUpdated() so each sentence counts once
      }
    }
  }
  return newLocation;
}

TinyGPSPlus& parser() { return s_gps; }

double hdop() { return s_gps.hdop.isValid() ? s_gps.hdop.hdop() : 100.0; }

bool commsOk(uint32_t nowMs) { return s_anyByte && nowMs - s_lastByteMs < GPS_COMMS_TIMEOUT_MS; }

bool hasLock(uint32_t nowMs) {
  return s_lastGood.valid && s_lastGood.atMs != 0 && nowMs - s_lastGood.atMs < LOCK_TIMEOUT_MS &&
         hdop() <= MAX_HDOP;
}

bool currentGoodFix(GoodFix& f, uint32_t nowMs) {
  TinyGPSLocation& loc = s_gps.location;
  if (!loc.isValid() || loc.age() > 2000) return false;
  if (hdop() > MAX_HDOP) return false;

  f.valid = true;
  f.lat = loc.lat();  // clears isUpdated()
  f.lng = loc.lng();
  f.altValid = s_gps.altitude.isValid();
  f.altM = f.altValid ? s_gps.altitude.meters() : 0;
  f.speedValid = s_gps.speed.isValid();
  f.speedKmh = f.speedValid ? s_gps.speed.kmph() : 0;
  f.courseValid = s_gps.course.isValid();
  f.courseDeg = f.courseValid ? s_gps.course.deg() : 0;
  f.hdop = hdop();
  f.satsTracked = s_gps.satellitesStats.nrSatsTracked();
  f.satsVisible = s_gps.satellitesStats.nrSatsVisible();
  f.quality = (int)loc.Quality();
  f.mode = (char)loc.Mode();
  f.utc = clk::isSet() ? clk::now() : 0;
  f.atMs = nowMs;
  s_lastGood = f;
  return true;
}

const GoodFix& lastGoodFix() { return s_lastGood; }

void setLastGoodFix(const GoodFix& f) { s_lastGood = f; }

}  // namespace gpsrx
