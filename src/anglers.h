#pragma once
// The anglers: up to MAX_ANGLERS names and colours, in button order (button 1
// is angler 1). The phone app sets them (BLE SET_ANGLER); they're kept on the
// card in /anglers.txt, which is readable and editable by hand:
//
//   # Anglers, in button order: name,colour
//   Jase,blue
//   Matt,orange
//
// Without the file (or with the card missing) the defaults are Jase (blue) and
// Matt (orange), as before anglers could be set.
//
// The logs name the angler in the comment ("Jase catch"), so a catch belongs to
// whichever angler has that name now. Renaming an angler starts their count on
// the logger again; the old name's catches stay in the logs under the old name.

#include <stddef.h>
#include <stdint.h>
#include <time.h>

#include "config.h"

namespace anglers {

enum Colour : uint8_t { Blue, Orange, Green, Purple, Teal, Pink, kColourCount };

struct Angler {
  char name[ANGLER_NAME_MAX + 1] = "";
  uint8_t colour = Blue;
};

// Loads /anglers.txt, or the defaults if the card or the file isn't there.
void begin();
// If begin() couldn't read the card, tries again. True if the anglers changed.
bool reloadIfNeeded();

int count();
const Angler& get(int i);
// The angler with this name (case-insensitive), or -1.
int find(const char* name);
// How many catch buttons are fitted (ANGLER_BUTTON_PINS). Anglers past this
// number are shown but have no button yet.
int buttons();

const char* colourName(uint8_t c);
uint32_t colourRgb(uint8_t c);  // 0xRRGGBB, for the screen

// A name is 1 to ANGLER_NAME_MAX characters: letters, digits, spaces, '-', '.'
// and the apostrophe, with no space at either end. The comma is out because
// the logs are CSV, and ':' because an undo comment ends with a time.
bool validName(const char* s, size_t len);

enum class SetResult { Applied, Invalid, SaveFailed };
// Checks the list (1 to MAX_ANGLERS anglers, valid and different names, known
// colours), saves it to the card and applies it. On Invalid, 'why' says what's
// wrong and nothing changes. On SaveFailed nothing changes either.
SetResult set(const Angler* list, int n, char* why, size_t whyLen);

// ---- Log comments ----
// A catch row's comment is "<name> catch". An undo row's comment is
// "<name> undo <time_utc of the catch>", or "<name> undo" when the undone
// catch had no time (made before the GPS gave the date).

// "Jase catch" -> "Jase". False if it isn't a catch comment.
bool parseCatch(const char* comment, char* name, size_t nameLen);
// "Jase undo 2026-11-20T03:12:44Z" -> "Jase", that time. catchUtc is 0 when
// the comment has no time. False if it isn't an undo comment.
bool parseUndo(const char* comment, char* name, size_t nameLen, time_t& catchUtc);

}  // namespace anglers
