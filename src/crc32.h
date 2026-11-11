#pragma once
// Standard CRC-32 (IEEE 802.3, zlib, reflected, poly 0xEDB88320).
// crc32Update(0, data, len) gives the usual CRC of 'data', and calls chain:
// crc32Update(crc32Update(0, a, n), b, m) == CRC of a||b.
// The phone page uses the same algorithm.

#include <stddef.h>
#include <stdint.h>

uint32_t crc32Update(uint32_t crc, const uint8_t* data, size_t len);
