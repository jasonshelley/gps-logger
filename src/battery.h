#pragma once
// Battery voltage, read through a 100k/100k divider from the board's 5V pin to
// PIN_BATT_ADC (docs/battery-poc.md). On battery power the 5V pin is the cell
// voltage; on USB or a charger's output it's that supply's voltage instead.

#include <stdint.h>

namespace battery {

enum class Source : uint8_t {
  Unknown,  // no reading yet, or nothing plausible (divider not fitted)
  Battery,  // a single Li-ion cell: 2.5-4.35 V
  External  // above any cell: USB on the board, or the bq24074 on charge
};

void begin();
// Samples every BATT_SAMPLE_MS. Cheap to call every loop.
void poll(uint32_t nowMs);

Source source();
// Smoothed voltage at the 5V pin, in millivolts. 0 until the first reading.
uint16_t millivolts();
// The latest raw (unsmoothed) reading, for the console.
uint16_t rawMillivolts();

}  // namespace battery
