#pragma once
// Wall clock. The system clock is set from GPS time (UTC). The TZ rule in
// config.h turns it into Sydney local time, AEST or AEDT as appropriate.
// The SD card's FAT timestamps also come from the system clock.

#include <stdint.h>
#include <time.h>

class TinyGPSPlus;

namespace clk {

void begin();

// Sets the system clock from the GPS when its date and time are valid and fresh.
// Call after feeding the GPS parser.
void syncFromGps(TinyGPSPlus& gps);

// True once the clock has been set from the GPS since boot.
bool isSet();

// Current UTC time (seconds). Only meaningful when isSet().
time_t now();

// "2026-11-11T08:15:02Z"
void formatIsoUtc(time_t t, char* out, size_t len);

// Local date as YYYYMMDD in 'out' (9 bytes), e.g. "20261111".
void localDateStamp(time_t t, char* out);

// Local "DD/MM/YYYY", "HH:MM:SS" and zone name ("AEST" or "AEDT").
void formatLocal(time_t t, char* date, size_t dateLen, char* timeStr, size_t timeLen,
                 char* zone, size_t zoneLen);

// Parses "YYYY-MM-DDTHH:MM:SSZ" back to UTC seconds. Returns 0 on failure.
time_t parseIsoUtc(const char* s);

}  // namespace clk
