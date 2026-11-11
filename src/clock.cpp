#include "clock.h"

#include <Arduino.h>
#include <TinyGPSPlus.h>
#include <stdlib.h>
#include <sys/time.h>

#include "config.h"

namespace clk {

static bool s_set = false;

void begin() {
  setenv("TZ", LOCAL_TZ, 1);
  tzset();
}

// Days from 1970-01-01 to the given civil date (proleptic Gregorian).
// Avoids timegm(), which newlib doesn't provide, and mktime(), which applies TZ.
static int64_t daysFromCivil(int y, unsigned m, unsigned d) {
  y -= m <= 2;
  const int era = (y >= 0 ? y : y - 399) / 400;
  const unsigned yoe = (unsigned)(y - era * 400);
  const unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
  const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return (int64_t)era * 146097 + (int64_t)doe - 719468;
}

static time_t utcFromFields(int y, int mo, int d, int h, int mi, int s) {
  return (time_t)(daysFromCivil(y, mo, d) * 86400LL + h * 3600 + mi * 60 + s);
}

void syncFromGps(TinyGPSPlus& gps) {
  if (!gps.date.isValid() || !gps.time.isValid()) return;
  if (!gps.time.isUpdated()) return;
  // Ignore a stale value (the receiver stopped sending time).
  if (gps.time.age() > 1500 || gps.date.age() > 1500) return;
  int year = gps.date.year();
  if (year < 2024 || year > 2099) return;  // receivers report 2000/2080 before they know the date

  time_t t = utcFromFields(year, gps.date.month(), gps.date.day(), gps.time.hour(),
                           gps.time.minute(), gps.time.second());
  // The NMEA time was correct when the sentence ended, gps.time.age() ago.
  t += gps.time.age() / 1000;

  time_t sys = time(nullptr);
  if (!s_set || llabs((long long)(sys - t)) > 1) {
    struct timeval tv = {t, 0};
    settimeofday(&tv, nullptr);
    s_set = true;
  }
  gps.time.value();  // clears isUpdated()
}

bool isSet() { return s_set; }

time_t now() { return time(nullptr); }

void formatIsoUtc(time_t t, char* out, size_t len) {
  struct tm tm;
  gmtime_r(&t, &tm);
  strftime(out, len, "%Y-%m-%dT%H:%M:%SZ", &tm);
}

void localDateStamp(time_t t, char* out) {
  struct tm tm;
  localtime_r(&t, &tm);
  strftime(out, 9, "%Y%m%d", &tm);
}

void formatLocal(time_t t, char* date, size_t dateLen, char* timeStr, size_t timeLen, char* zone,
                 size_t zoneLen) {
  struct tm tm;
  localtime_r(&t, &tm);
  strftime(date, dateLen, "%d/%m/%Y", &tm);
  strftime(timeStr, timeLen, "%H:%M:%S", &tm);
  strftime(zone, zoneLen, "%Z", &tm);
}

time_t parseIsoUtc(const char* s) {
  int y, mo, d, h, mi, sec;
  if (sscanf(s, "%4d-%2d-%2dT%2d:%2d:%2dZ", &y, &mo, &d, &h, &mi, &sec) != 6) return 0;
  return utcFromFields(y, mo, d, h, mi, sec);
}

}  // namespace clk
