#pragma once
// Debounced catch buttons and mode switch. All inputs are active low with
// internal pull-ups.

#include <stdint.h>

class Button {
 public:
  Button(uint8_t pin, uint32_t debounceMs);
  void begin();
  void update(uint32_t nowMs);
  // True once per press: after the pin has been low for the debounce time.
  // Re-arms only after the button has been released (high for the debounce time).
  bool takePress();

 private:
  uint8_t pin_;
  uint32_t debounceMs_;
  bool rawLow_ = false;
  bool stableLow_ = false;
  uint32_t changedAt_ = 0;
  bool pressed_ = false;
};

enum class Mode : uint8_t { Logging, Transfer };

class ModeSwitch {
 public:
  ModeSwitch(uint8_t pin, uint32_t debounceMs);
  // Reads the switch straight away, so the device boots in whatever mode the
  // switch is in (no default mode while it settles).
  void begin();
  void update(uint32_t nowMs);
  Mode mode() const { return mode_; }
  // True once after the debounced mode changes.
  bool takeChange();

 private:
  uint8_t pin_;
  uint32_t debounceMs_;
  bool rawLow_ = false;
  uint32_t changedAt_ = 0;
  Mode mode_ = Mode::Logging;
  bool changed_ = false;
};

const char* modeName(Mode m);
