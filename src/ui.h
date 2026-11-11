#pragma once
// The two screens (requirements Q10): Logger and Transfer.
// Call only from the main loop task.

#include <stdint.h>

#include "inputs.h"
#include "track_logger.h"

namespace ui {

void begin(Mode initial);
void showMode(Mode m);

// Logger screen. 'slow' refreshes satellites, HDOP, course and speed (once a second).
void refreshLogger(uint32_t nowMs, bool slow);
void showCatch(Angler who, bool savedOk, uint32_t nowMs);

void refreshTransfer(uint32_t nowMs);

}  // namespace ui
