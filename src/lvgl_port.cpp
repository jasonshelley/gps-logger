#include "lvgl_port.h"

#include <lvgl.h>

#include "st7789.h"

// One partial buffer of 40 lines (~13.7 KB). The flush is synchronous, so a
// second buffer wouldn't help.
static const uint32_t kBufLines = 40;
static lv_color_t s_buf[LCD_WIDTH * kBufLines];
static lv_disp_draw_buf_t s_drawBuf;
static lv_disp_drv_t s_dispDrv;

static void flushCb(lv_disp_drv_t* drv, const lv_area_t* area, lv_color_t* colors) {
  lcdDrawWindow(area->x1, area->y1, area->x2, area->y2, (const uint16_t*)&colors->full);
  lv_disp_flush_ready(drv);
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
