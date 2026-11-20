#include "inputs.h"

#include <Arduino.h>

Button::Button(uint8_t pin, uint32_t debounceMs, uint32_t holdMs)
    : pin_(pin), debounceMs_(debounceMs), holdMs_(holdMs) {}

void Button::begin() {
  pinMode(pin_, INPUT_PULLUP);
  rawLow_ = stableLow_ = digitalRead(pin_) == LOW;
  // A button held down at boot (BOOT held for the bootloader, say) reports
  // nothing until it has been released and pressed again.
  armed_ = false;
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
    if (stableLow_) {
      armed_ = true;
      held_ = false;
      downAt_ = nowMs;
    } else if (armed_) {
      if (!held_) press_ = true;
      armed_ = false;
    }
  }
  if (stableLow_ && armed_ && !held_ && nowMs - downAt_ >= holdMs_) {
    held_ = true;
    hold_ = true;
  }
}

bool Button::takePress() {
  bool p = press_;
  press_ = false;
  return p;
}

bool Button::takeHold() {
  bool h = hold_;
  hold_ = false;
  return h;
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
