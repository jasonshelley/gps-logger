#include "inputs.h"

#include <Arduino.h>

Button::Button(uint8_t pin, uint32_t debounceMs) : pin_(pin), debounceMs_(debounceMs) {}

void Button::begin() {
  pinMode(pin_, INPUT_PULLUP);
  rawLow_ = stableLow_ = digitalRead(pin_) == LOW;
  // A button held down at boot doesn't count as a press.
  changedAt_ = millis();
}

void Button::update(uint32_t nowMs) {
  bool low = digitalRead(pin_) == LOW;
  if (low != rawLow_) {
    rawLow_ = low;
    changedAt_ = nowMs;
  }
  if (rawLow_ != stableLow_ && nowMs - changedAt_ >= debounceMs_) {
    stableLow_ = rawLow_;
    if (stableLow_) pressed_ = true;
  }
}

bool Button::takePress() {
  bool p = pressed_;
  pressed_ = false;
  return p;
}

ModeSwitch::ModeSwitch(uint8_t pin, uint32_t debounceMs) : pin_(pin), debounceMs_(debounceMs) {}

void ModeSwitch::begin() {
  pinMode(pin_, INPUT_PULLUP);
  delay(2);  // let the pull-up charge the line
  // Majority of a few reads, so one noisy sample can't pick the wrong mode.
  int lows = 0;
  for (int i = 0; i < 5; i++) {
    if (digitalRead(pin_) == LOW) lows++;
    delay(2);
  }
  rawLow_ = lows >= 3;
  mode_ = rawLow_ ? Mode::Transfer : Mode::Logging;
  changedAt_ = millis();
  changed_ = false;
}

void ModeSwitch::update(uint32_t nowMs) {
  bool low = digitalRead(pin_) == LOW;
  if (low != rawLow_) {
    rawLow_ = low;
    changedAt_ = nowMs;
  }
  Mode wanted = rawLow_ ? Mode::Transfer : Mode::Logging;
  if (wanted != mode_ && nowMs - changedAt_ > debounceMs_) {
    mode_ = wanted;
    changed_ = true;
  }
}

bool ModeSwitch::takeChange() {
  bool c = changed_;
  changed_ = false;
  return c;
}

const char* modeName(Mode m) {
  return m == Mode::Transfer ? "Transfer" : "Logging";
}
