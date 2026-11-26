#include "lvgl_port.h"

#include <lvgl.h>

#include "st7789.h"

// One partial buffer of 40 lines (~13.7 KB). The flush is synchronous, so a
// second buffer wouldn't help.
static const uint32_t kBufLines = 40;
static lv_color_t s_buf[LCD_WIDTH * kBufLines];
static lv_disp_draw_buf_t s_drawBuf;
static lv_disp_drv_t s_dispDrv;
static Print* s_shotOut = nullptr;  // set while lvglScreenshot() redraws the screen

// Screenshot format, read by tools/screenshot.py: for each area LVGL flushes,
// "AREA x1 y1 x2 y2" and then one line of hex per row, each pixel 4 hex digits
// of RGB565.
static void sendArea(const lv_area_t* area, const lv_color_t* colors) {
  static const char kHex[] = "0123456789abcdef";
  int w = area->x2 - area->x1 + 1, h = area->y2 - area->y1 + 1;
  s_shotOut->printf("AREA %d %d %d %d\n", area->x1, area->y1, area->x2, area->y2);
  char line[LCD_WIDTH * 4 + 2];
  for (int y = 0; y < h; y++) {
    char* p = line;
    for (int x = 0; x < w; x++) {
      uint16_t c = colors[y * w + x].full;
      *p++ = kHex[c >> 12];
      *p++ = kHex[(c >> 8) & 15];
      *p++ = kHex[(c >> 4) & 15];
      *p++ = kHex[c & 15];
    }
    *p++ = '\n';
    s_shotOut->write((const uint8_t*)line, p - line);
  }
}

static void flushCb(lv_disp_drv_t* drv, const lv_area_t* area, lv_color_t* colors) {
  lcdDrawWindow(area->x1, area->y1, area->x2, area->y2, (const uint16_t*)&colors->full);
  if (s_shotOut) sendArea(area, colors);
  lv_disp_flush_ready(drv);
}

void lvglScreenshot(Print& out) {
  out.printf("SCREENSHOT %d %d\n", LCD_WIDTH, LCD_HEIGHT);
  s_shotOut = &out;
  lv_obj_invalidate(lv_scr_act());
  lv_obj_invalidate(lv_layer_top());
  lv_refr_now(nullptr);
  s_shotOut = nullptr;
  out.println("END SCREENSHOT");
}

void lvglInit() {
  lv_init();
  lv_disp_draw_buf_init(&s_drawBuf, s_buf, nullptr, LCD_WIDTH * kBufLines);

  lv_disp_drv_init(&s_dispDrv);
  s_dispDrv.hor_res = LCD_WIDTH;
  s_dispDrv.ver_res = LCD_HEIGHT;
  s_dispDrv.flush_cb = flushCb;
  s_dispDrv.draw_buf = &s_drawBuf;
  // The old sketch set full_refresh = 1, which redraws all 320 lines on every
  // change. Partial refresh sends only the dirty areas.
  s_dispDrv.full_refresh = 0;
  lv_disp_drv_register(&s_dispDrv);
}

void lvglTask() {
  lv_timer_handler();
}
