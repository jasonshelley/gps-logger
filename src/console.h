#pragma once
// USB serial console (requirements Q11). Non-blocking; input is limited to
// CONSOLE_LINE_MAX characters per line and longer lines are rejected.

#include <stdint.h>

namespace console {

void begin();
// Reads whatever is waiting and runs a command when a full line has arrived.
void poll(uint32_t nowMs);

}  // namespace console
