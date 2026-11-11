#include "crc32.h"

static uint32_t s_table[256];
static bool s_ready = false;

static void buildTable() {
  for (uint32_t i = 0; i < 256; i++) {
    uint32_t c = i;
    for (int k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
    s_table[i] = c;
  }
  s_ready = true;
}

uint32_t crc32Update(uint32_t crc, const uint8_t* data, size_t len) {
  if (!s_ready) buildTable();
  crc = ~crc;
  for (size_t i = 0; i < len; i++) crc = s_table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
  return ~crc;
}
