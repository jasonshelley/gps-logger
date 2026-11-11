#include "ui.h"

#include <Arduino.h>
#include <lvgl.h>

#include "ble_transfer.h"
#include "clock.h"
#include "config.h"
#include "gps.h"
#include "st7789.h"
#include "storage.h"

namespace ui {

static lv_obj_t* s_loggerScreen;
static lv_obj_t* s_transferScreen;

// Logger screen
static lv_obj_t* s_loggerBox;
static lv_obj_t* s_satArc;
static lv_obj_t* s_satLabel;
static lv_obj_t* s_hdopArc;
static lv_obj_t* s_hdopLabel;
static lv_obj_t* s_courseLabel;
static lv_obj_t* s_cardinalLabel;
static lv_obj_t* s_speedLabel;
static lv_obj_t* s_dateLabel;
static lv_obj_t* s_timeLabel;
static lv_obj_t* s_zoneLabel;
static lv_obj_t* s_jaseLabel;
static lv_obj_t* s_mattLabel;
static lv_obj_t* s_distanceLabel;
static lv_obj_t* s_statusLabel;
static lv_obj_t* s_banner;
static lv_obj_t* s_bannerLabel;
static uint32_t s_bannerUntil = 0;

// Transfer screen
static lv_obj_t* s_transferBox;
static lv_obj_t* s_bleLabel;
static lv_obj_t* s_fileLabel;
static lv_obj_t* s_progressBar;
static lv_obj_t* s_progressLabel;
static lv_obj_t* s_filesLeftLabel;
static lv_obj_t* s_lastMsgLabel;

static const lv_color_t kWhite = lv_color_hex(0xFFFFFF);
static const lv_color_t kGrey = lv_color_hex(0x9E9E9E);

static lv_color_t palette(lv_palette_t p) { return lv_palette_main(p); }

// Setting a style invalidates the object even when the value is unchanged, and
// for the screen-sized boxes that means a full redraw. These only touch the
// style when the colour changes.
static void setBorder(lv_obj_t* obj, lv_color_t c) {
  if (lv_obj_get_style_border_color(obj, LV_PART_MAIN).full != c.full)
    lv_obj_set_style_border_color(obj, c, 0);
}
static void setArcColour(lv_obj_t* arc, lv_color_t c) {
  if (lv_obj_get_style_arc_color(arc, LV_PART_INDICATOR).full != c.full)
    lv_obj_set_style_arc_color(arc, c, LV_PART_INDICATOR);
}
static void setTextColour(lv_obj_t* obj, lv_color_t c) {
  if (lv_obj_get_style_text_color(obj, LV_PART_MAIN).full != c.full)
    lv_obj_set_style_text_color(obj, c, 0);
}

// lv_label_set_text always invalidates; skip it when nothing changed.
static void setText(lv_obj_t* label, const char* text) {
  if (strcmp(lv_label_get_text(label), text) != 0) lv_label_set_text(label, text);
}

static lv_obj_t* makeBox(lv_obj_t* screen) {
  lv_obj_set_style_bg_color(screen, lv_color_hex(0x101010), 0);
  lv_obj_t* box = lv_obj_create(screen);
  lv_obj_set_size(box, LCD_WIDTH, LCD_HEIGHT);
  lv_obj_set_pos(box, 0, 0);
  lv_obj_set_style_radius(box, 25, 0);
  lv_obj_set_style_bg_color(box, lv_color_hex(0x000000), 0);
  lv_obj_set_style_bg_opa(box, LV_OPA_COVER, 0);
  lv_obj_set_style_border_width(box, 3, 0);
  lv_obj_set_style_border_color(box, palette(LV_PALETTE_RED), 0);
  lv_obj_set_style_pad_all(box, 0, 0);
  lv_obj_clear_flag(box, LV_OBJ_FLAG_SCROLLABLE);
  return box;
}

static lv_obj_t* makeLabel(lv_obj_t* parent, const lv_font_t* font, lv_align_t align, int x, int y,
                           const char* text = "--") {
  lv_obj_t* l = lv_label_create(parent);
  lv_obj_set_style_text_font(l, font, 0);
  lv_obj_set_style_text_color(l, kWhite, 0);
  lv_label_set_text(l, text);
  lv_obj_align(l, align, x, y);
  return l;
}

static void makeSeparator(lv_obj_t* parent, int y) {
  static lv_point_t pts[] = {{0, 0}, {130, 0}};
  lv_obj_t* line = lv_line_create(parent);
  lv_line_set_points(line, pts, 2);
  lv_obj_set_style_line_color(line, palette(LV_PALETTE_GREY), 0);
  lv_obj_set_style_line_width(line, 2, 0);
  lv_obj_set_style_line_rounded(line, true, 0);
  lv_obj_align(line, LV_ALIGN_TOP_MID, 0, y);
}

static lv_obj_t* makeArc(lv_obj_t* parent, int x, int32_t maxValue, lv_obj_t** label) {
  lv_obj_t* arc = lv_arc_create(parent);
  lv_obj_set_size(arc, 75, 75);
  lv_arc_set_rotation(arc, 135);
  lv_arc_set_bg_angles(arc, 0, 270);
  lv_arc_set_range(arc, 0, maxValue);
  lv_arc_set_value(arc, 0);
  lv_obj_set_style_arc_width(arc, 6, LV_PART_MAIN);
  lv_obj_set_style_arc_width(arc, 6, LV_PART_INDICATOR);
  lv_obj_remove_style(arc, nullptr, LV_PART_KNOB);
  lv_obj_clear_flag(arc, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_align(arc, LV_ALIGN_TOP_MID, x, 8);
  *label = lv_label_create(arc);
  lv_obj_set_style_text_color(*label, kWhite, 0);
  lv_obj_set_style_text_align(*label, LV_TEXT_ALIGN_CENTER, 0);
  lv_obj_center(*label);
  return arc;
}

static void buildLogger() {
  s_loggerScreen = lv_obj_create(nullptr);
  s_loggerBox = makeBox(s_loggerScreen);

  s_satArc = makeArc(s_loggerBox, -39, 16, &s_satLabel);
  lv_label_set_text(s_satLabel, "Sats\n--");
  s_hdopArc = makeArc(s_loggerBox, 39, 1000, &s_hdopLabel);
  lv_label_set_text(s_hdopLabel, "HDOP\n--");

  makeSeparator(s_loggerBox, 90);
  s_courseLabel = makeLabel(s_loggerBox, &lv_font_montserrat_24, LV_ALIGN_TOP_MID, -36, 98);
  s_cardinalLabel = makeLabel(s_loggerBox, &lv_font_montserrat_24, LV_ALIGN_TOP_MID, 40, 98);
  s_speedLabel = makeLabel(s_loggerBox, &lv_font_montserrat_24, LV_ALIGN_TOP_MID, 0, 128);

  makeSeparator(s_loggerBox, 162);
  s_dateLabel = makeLabel(s_loggerBox, &lv_font_montserrat_20, LV_ALIGN_TOP_MID, 0, 168);
  s_timeLabel = makeLabel(s_loggerBox, &lv_font_montserrat_20, LV_ALIGN_TOP_MID, -14, 194);
  s_zoneLabel = makeLabel(s_loggerBox, &lv_font_montserrat_12, LV_ALIGN_TOP_MID, 48, 200, "");
  lv_obj_set_style_text_color(s_zoneLabel, kGrey, 0);

  makeSeparator(s_loggerBox, 222);
  s_jaseLabel = makeLabel(s_loggerBox, &lv_font_montserrat_20, LV_ALIGN_TOP_MID, -38, 228, "Jase 0");
  s_mattLabel = makeLabel(s_loggerBox, &lv_font_montserrat_20, LV_ALIGN_TOP_MID, 38, 228, "Matt 0");
  s_distanceLabel = makeLabel(s_loggerBox, &lv_font_montserrat_14, LV_ALIGN_TOP_MID, 0, 256);
  s_statusLabel = makeLabel(s_loggerBox, &lv_font_montserrat_12, LV_ALIGN_TOP_MID, 0, 280);

  // Catch banner, hidden until a button is pressed.
  s_banner = lv_obj_create(s_loggerBox);
  lv_obj_set_size(s_banner, 150, 64);
  lv_obj_align(s_banner, LV_ALIGN_TOP_MID, 0, 120);
  lv_obj_set_style_radius(s_banner, 12, 0);
  lv_obj_set_style_border_width(s_banner, 2, 0);
  lv_obj_set_style_border_color(s_banner, kWhite, 0);
  lv_obj_set_style_pad_all(s_banner, 0, 0);
  lv_obj_clear_flag(s_banner, LV_OBJ_FLAG_SCROLLABLE);
  s_bannerLabel = lv_label_create(s_banner);
  lv_obj_set_style_text_font(s_bannerLabel, &lv_font_montserrat_20, 0);
  lv_obj_set_style_text_color(s_bannerLabel, kWhite, 0);
  lv_obj_set_style_text_align(s_bannerLabel, LV_TEXT_ALIGN_CENTER, 0);
  lv_obj_center(s_bannerLabel);
  lv_obj_add_flag(s_banner, LV_OBJ_FLAG_HIDDEN);
}

static void buildTransfer() {
  s_transferScreen = lv_obj_create(nullptr);
  s_transferBox = makeBox(s_transferScreen);
  lv_obj_set_style_border_color(s_transferBox, palette(LV_PALETTE_BLUE), 0);

  makeLabel(s_transferBox, &lv_font_montserrat_24, LV_ALIGN_TOP_MID, 0, 16, "Transfer");
  s_bleLabel = makeLabel(s_transferBox, &lv_font_montserrat_14, LV_ALIGN_TOP_MID, 0, 52, "");
  makeSeparator(s_transferBox, 80);

  lv_obj_t* cap = makeLabel(s_transferBox, &lv_font_montserrat_12, LV_ALIGN_TOP_MID, 0, 90, "File");
  lv_obj_set_style_text_color(cap, kGrey, 0);
  s_fileLabel = makeLabel(s_transferBox, &lv_font_montserrat_14, LV_ALIGN_TOP_MID, 0, 106);

  s_progressBar = lv_bar_create(s_transferBox);
  lv_obj_set_size(s_progressBar, 140, 14);
  lv_obj_align(s_progressBar, LV_ALIGN_TOP_MID, 0, 130);
  lv_bar_set_range(s_progressBar, 0, 1000);
  lv_obj_set_style_bg_color(s_progressBar, palette(LV_PALETTE_GREEN), LV_PART_INDICATOR);
  s_progressLabel = makeLabel(s_transferBox, &lv_font_montserrat_12, LV_ALIGN_TOP_MID, 0, 150, "");

  makeSeparator(s_transferBox, 175);
  s_filesLeftLabel = makeLabel(s_transferBox, &lv_font_montserrat_20, LV_ALIGN_TOP_MID, 0, 186, "");
  s_lastMsgLabel = makeLabel(s_transferBox, &lv_font_montserrat_14, LV_ALIGN_TOP_MID, 0, 222, "");
  lv_label_set_long_mode(s_lastMsgLabel, LV_LABEL_LONG_WRAP);
  lv_obj_set_width(s_lastMsgLabel, 150);
  lv_obj_set_style_text_align(s_lastMsgLabel, LV_TEXT_ALIGN_CENTER, 0);

  lv_obj_t* hint = makeLabel(s_transferBox, &lv_font_montserrat_12, LV_ALIGN_TOP_MID, 0, 272,
                             "Open the logger page\nin Chrome on Android");
  lv_obj_set_style_text_color(hint, kGrey, 0);
  lv_obj_set_style_text_align(hint, LV_TEXT_ALIGN_CENTER, 0);
}

void begin(Mode initial) {
  buildLogger();
  buildTransfer();
  showMode(initial);
}

void showMode(Mode m) {
  lv_obj_t* screen = m == Mode::Transfer ? s_transferScreen : s_loggerScreen;
  if (lv_scr_act() != screen) lv_scr_load(screen);
}

static void refreshSlow(uint32_t nowMs) {
  TinyGPSPlus& gps = gpsrx::parser();
  bool lock = gpsrx::hasLock(nowMs);
  bool comms = gpsrx::commsOk(nowMs);
  char buf[32];

  // Satellites tracked
  int sats = comms ? gps.satellitesStats.nrSatsTracked() : 0;
  lv_palette_t satColour = lock ? LV_PALETTE_GREEN : sats > 1 ? LV_PALETTE_ORANGE : LV_PALETTE_RED;
  setArcColour(s_satArc, palette(satColour));
  if (lv_arc_get_value(s_satArc) != (sats > 16 ? 16 : sats)) lv_arc_set_value(s_satArc, sats > 16 ? 16 : sats);
  if (comms) snprintf(buf, sizeof(buf), "Sats\n%d", sats);
  else snprintf(buf, sizeof(buf), "Sats\n--");
  setText(s_satLabel, buf);

  // HDOP: a fuller arc means better accuracy.
  double hdop = comms ? gpsrx::hdop() : 100.0;
  int v = 1000 - (int)(hdop * 10);
  lv_palette_t hdopColour = hdop <= MAX_HDOP ? LV_PALETTE_GREEN : hdop < 50 ? LV_PALETTE_ORANGE : LV_PALETTE_RED;
  setArcColour(s_hdopArc, palette(hdopColour));
  if (v < 0) v = 0;
  if (lv_arc_get_value(s_hdopArc) != v) lv_arc_set_value(s_hdopArc, v);
  if (comms && gps.hdop.isValid()) snprintf(buf, sizeof(buf), "HDOP\n%.1f", hdop);
  else snprintf(buf, sizeof(buf), "HDOP\n--");
  setText(s_hdopLabel, buf);

  // Course and speed: "--" when invalid, stale or HDOP is over the limit.
  bool good = comms && hdop <= MAX_HDOP;
  if (good && gps.course.isValid() && gps.course.age() < 3000) {
    double deg = gps.course.deg();
    snprintf(buf, sizeof(buf), "%.0f\xC2\xB0", deg);  // UTF-8 degree sign
    setText(s_courseLabel, buf);
    setText(s_cardinalLabel, TinyGPSPlus::cardinal(deg));
  } else {
    setText(s_courseLabel, "--");
    setText(s_cardinalLabel, "--");
  }
  if (good && gps.speed.isValid() && gps.speed.age() < 3000) {
    snprintf(buf, sizeof(buf), "%.1f km/h", gps.speed.kmph());
    setText(s_speedLabel, buf);
  } else {
    setText(s_speedLabel, "--");
  }
}

static void refreshFast(uint32_t nowMs) {
  char buf[40];
  bool comms = gpsrx::commsOk(nowMs);
  setBorder(s_loggerBox, palette(comms ? LV_PALETTE_GREEN : LV_PALETTE_RED));

  // Local date and time from the system clock (set from the GPS), so it never flickers.
  if (clk::isSet()) {
    char date[16], timeStr[12], zone[8];
    clk::formatLocal(clk::now(), date, sizeof(date), timeStr, sizeof(timeStr), zone, sizeof(zone));
    setText(s_dateLabel, date);
    setText(s_timeLabel, timeStr);
    setText(s_zoneLabel, zone);
  } else {
    setText(s_dateLabel, "--");
    setText(s_timeLabel, "--");
    setText(s_zoneLabel, "");
  }

  const DayStats& st = tracklog::stats();
  snprintf(buf, sizeof(buf), "Jase %lu", (unsigned long)st.jase);
  setText(s_jaseLabel, buf);
  snprintf(buf, sizeof(buf), "Matt %lu", (unsigned long)st.matt);
  setText(s_mattLabel, buf);

  if (!st.known) snprintf(buf, sizeof(buf), "Today --");
  else if (st.distanceM < 1000) snprintf(buf, sizeof(buf), "Today %.0f m", st.distanceM);
  else snprintf(buf, sizeof(buf), "Today %.2f km", st.distanceM / 1000.0);
  setText(s_distanceLabel, buf);

  const char* state;
  lv_palette_t colour;
  if (!storage::mounted() || !tracklog::lastWriteOk()) {
    state = "SD error";
    colour = LV_PALETTE_RED;
  } else if (!gpsrx::hasLock(nowMs)) {
    state = "No fix";
    colour = LV_PALETTE_ORANGE;
  } else {
    state = "OK";
    colour = LV_PALETTE_GREEN;
  }
  if (st.known) snprintf(buf, sizeof(buf), "%s  |  %lu pts", state, (unsigned long)st.points);
  else snprintf(buf, sizeof(buf), "%s  |  -- pts", state);
  setText(s_statusLabel, buf);
  setTextColour(s_statusLabel, palette(colour));

  if (s_bannerUntil && (int32_t)(nowMs - s_bannerUntil) >= 0) {
    lv_obj_add_flag(s_banner, LV_OBJ_FLAG_HIDDEN);
    s_bannerUntil = 0;
  }
}

void refreshLogger(uint32_t nowMs, bool slow) {
  if (slow) refreshSlow(nowMs);
  refreshFast(nowMs);
}

void showCatch(Angler who, bool savedOk, uint32_t nowMs) {
  char buf[32];
  if (savedOk) snprintf(buf, sizeof(buf), "%s catch!", tracklog::anglerName(who));
  else snprintf(buf, sizeof(buf), "%s catch!\nNOT SAVED", tracklog::anglerName(who));
  lv_label_set_text(s_bannerLabel, buf);
  lv_color_t bg = !savedOk ? palette(LV_PALETTE_RED)
                  : who == Angler::Jase ? palette(LV_PALETTE_BLUE) : palette(LV_PALETTE_DEEP_ORANGE);
  lv_obj_set_style_bg_color(s_banner, bg, 0);
  lv_obj_clear_flag(s_banner, LV_OBJ_FLAG_HIDDEN);
  lv_obj_move_foreground(s_banner);
  s_bannerUntil = nowMs + CATCH_BANNER_MS;
  if (s_bannerUntil == 0) s_bannerUntil = 1;
  refreshFast(nowMs);  // counts update together with the banner
}

void refreshTransfer(uint32_t) {
  const bletx::Status& st = bletx::status();
  char buf[48];

  setBorder(s_transferBox,
            palette(st.connected ? LV_PALETTE_GREEN : st.advertising ? LV_PALETTE_ORANGE : LV_PALETTE_RED));
  if (st.connected) snprintf(buf, sizeof(buf), LV_SYMBOL_BLUETOOTH " Connected");
  else if (st.advertising) snprintf(buf, sizeof(buf), LV_SYMBOL_BLUETOOTH " Waiting for phone");
  else snprintf(buf, sizeof(buf), LV_SYMBOL_BLUETOOTH " Off");
  setText(s_bleLabel, buf);

  setText(s_fileLabel, st.file[0] ? st.file : "--");
  int permille = st.size ? (int)((uint64_t)st.sent * 1000 / st.size) : 0;
  if (lv_bar_get_value(s_progressBar) != permille) lv_bar_set_value(s_progressBar, permille, LV_ANIM_OFF);
  if (st.size) snprintf(buf, sizeof(buf), "%.1f / %.1f KB", st.sent / 1024.0, st.size / 1024.0);
  else buf[0] = 0;
  setText(s_progressLabel, buf);

  if (st.filesLeft < 0) snprintf(buf, sizeof(buf), "-- files left");
  else if (st.filesLeft == 1) snprintf(buf, sizeof(buf), "1 file left");
  else snprintf(buf, sizeof(buf), "%d files left", st.filesLeft);
  setText(s_filesLeftLabel, buf);
  setText(s_lastMsgLabel, st.lastMsg);
}

}  // namespace ui
