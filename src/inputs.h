#pragma once
// Debounced buttons and mode switch. All inputs are active low with pull-ups.

#include <stdint.h>

// A button with two gestures:
//   press: released before holdMs. Reported on release.
//   hold:  held for holdMs. Reported once, while still held; the release that
//          follows reports nothing.
class Button {
 public:
  Button(uint8_t pin, uint32_t debounceMs, uint32_t holdMs);
  void begin();
  void update(uint32_t nowMs);
  // True once per short press, when it's released.
  bool takePress();
  // True once per hold, as soon as it reaches holdMs.
  bool takeHold();
  // Down right now (debounced).
  bool isDown() const { return stableLow_; }

 private:
  uint8_t pin_;
  uint32_t debounceMs_;
  uint32_t holdMs_;
  bool rawLow_ = false;
  bool stableLow_ = false;
  bool armed_ = false;   // went down after begin(): a button held at boot reports nothing
  bool held_ = false;    // this press already reported a hold
  uint32_t changedAt_ = 0;
  uint32_t downAt_ = 0;
  bool press_ = false;
  bool hold_ = false;
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
