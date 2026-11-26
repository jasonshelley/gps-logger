#include "battery.h"

#include <Arduino.h>

#include "config.h"

namespace battery {

static uint16_t s_mv = 0;     // smoothed
static uint16_t s_rawMv = 0;  // latest sample set
static uint32_t s_lastSampleMs = 0;
static bool s_sampled = false;

void begin() {
  analogReadResolution(12);
  // 11 dB (the same as 12 dB on the C6) is the widest range; the divider puts at most
  // about 2.2 V on the pin. analogReadMilliVolts() applies the chip's own calibration.
  analogSetPinAttenuation(PIN_BATT_ADC, ADC_11db);
  poll(millis());
}

static uint16_t sample() {
  uint32_t sum = 0;
  for (int i = 0; i < BATT_SAMPLES; i++) sum += analogReadMilliVolts(PIN_BATT_ADC);
  float pinMv = (float)sum / BATT_SAMPLES;
  float mv = pinMv * BATT_DIVIDER * BATT_CALIBRATION;
  if (mv < 0) mv = 0;
  if (mv > 65535) mv = 65535;
  return (uint16_t)(mv + 0.5f);
}

void poll(uint32_t nowMs) {
  if (s_sampled && nowMs - s_lastSampleMs < BATT_SAMPLE_MS) return;
  s_lastSampleMs = nowMs;
  s_rawMv = sample();
  // Light smoothing, so a backlight change or an SD write doesn't make the display flicker.
  // The first reading, and any jump of more than 300 mV (USB plugged in or out), is taken as is.
  if (!s_sampled || abs((int)s_rawMv - (int)s_mv) > 300) s_mv = s_rawMv;
  else s_mv = (uint16_t)((s_mv * 3 + s_rawMv + 2) / 4);
  s_sampled = true;
}

Source source() {
  if (!s_sampled || s_mv < BATT_MIN_PLAUSIBLE_MV) return Source::Unknown;
  if (s_mv > BATT_EXTERNAL_MV) return Source::External;
  return Source::Battery;
}

uint16_t millivolts() { return s_mv; }
uint16_t rawMillivolts() { return s_rawMv; }

}  // namespace battery
