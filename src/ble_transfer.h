#pragma once
// Bluetooth LE file transfer to the phone page (web/index.html).
// Protocol: docs/ble-protocol.md.
//
// NimBLE callbacks only queue requests; all SD access and notifications
// happen in loop(), on the main task.

#include <stdint.h>

namespace bletx {

struct Status {
  bool advertising = false;
  bool connected = false;
  bool sending = false;
  char file[32] = "";       // file being sent, or last file sent
  uint32_t sent = 0;        // bytes of 'file' sent so far
  uint32_t size = 0;
  int filesLeft = -1;       // log files still in the root folder; -1 = unknown
  char lastMsg[48] = "";    // e.g. "Saved gps20261111.csv"
};

// Turns Bluetooth on (first call) and starts advertising.
void start();
// Stops any transfer, disconnects the phone and stops advertising.
void stop();
// Call every loop pass while in Transfer mode.
void loop(uint32_t nowMs);

const Status& status();

}  // namespace bletx
