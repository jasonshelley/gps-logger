#pragma once
// LVGL 8 display glue for the ST7789. Ported from Waveshare's LVGL_Driver.cpp.
// The tick comes from LV_TICK_CUSTOM (esp_timer_get_time) in lv_conf.h.

#include <Print.h>

// Call after lcdInit().
void lvglInit();

// Call often from loop(); runs LVGL timers and redraws dirty areas.
void lvglTask();

// Redraws the whole screen and also sends it to `out` as hex (console command
// "screenshot"; tools/screenshot.py turns it into a PNG).
void lvglScreenshot(Print& out);
