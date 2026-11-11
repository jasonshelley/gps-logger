#pragma once
// ST7789 172x320 SPI panel driver for the Waveshare ESP32-C6-LCD-1.47.
// Ported from Waveshare's Display_ST7789.cpp (the version the old sketch used).
// The init sequence is unchanged.

#include <stdint.h>

#define LCD_WIDTH  172
#define LCD_HEIGHT 320

// Starts the shared SPI bus, resets the panel and runs the init sequence.
// Leaves LCD CS high so the SD card can use the bus afterwards.
void lcdInit();

// Writes a block of RGB565 pixels (LVGL's byte order) to the given window, inclusive.
void lcdDrawWindow(uint16_t x1, uint16_t y1, uint16_t x2, uint16_t y2, const uint16_t* pixels);

// 0-100 %.
void lcdSetBacklight(uint8_t percent);
