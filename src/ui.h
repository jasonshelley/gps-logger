#pragma once
// The two screens (requirements Q10): Logger and Transfer.
// Call only from the main loop task.

#include <stdint.h>

#include "inputs.h"
#include "track_logger.h"

namespace ui {

void begin(Mode initial);
void showMode(Mode m);

// Logger screen: status strip, catch counts, trip meter, speed and course, GPS.
// 'slow' is unused: everything is cheap to refresh, since unchanged text isn't redrawn.
void refreshLogger(uint32_t nowMs, bool slow);
// The catch banner: the angler's new count for CATCH_BANNER_MS (angler is 0-based).
void showCatch(int angler, bool savedOk, uint32_t nowMs);
// The same banner after a hold: undone, nothing to undo, or not saved.
void showUndo(int angler, tracklog::UndoResult r, uint32_t nowMs);
// The anglers changed: rebuilds the catches card.
void anglersChanged();
// The details page (date, satellites, HDOP, position, card, firmware) for DETAILS_PAGE_MS.
void showDetails(uint32_t nowMs);

void refreshTransfer(uint32_t nowMs);

}  // namespace ui
