#include "ui.h"

#include <Arduino.h>
#include <lvgl.h>
#include <time.h>

#include "anglers.h"
#include "battery.h"
#include "ble_transfer.h"
#include "clock.h"
#include "config.h"
#include "fw_version.h"  // generated at build time by tools/fw_version.py
#include "gps.h"
#include "st7789.h"
#include "storage.h"
#include "trip_meter.h"

namespace ui {

static lv_obj_t* s_loggerScreen;
static lv_obj_t* s_transferScreen;

// ---- Logger screen (layout A: catches first) ----
// From the top: a status strip (GPS state on the left, battery voltage in the
// middle, local time on the right), then cards: the two catch counts, the trip meter, and side by side
// speed and course, and satellites and HDOP (shown with or without a fix). The
// border is the health light: green logging, orange no fix, red no GPS or a
// card error.
static lv_obj_t* s_loggerBox;
static lv_obj_t* s_stateDot;
static lv_obj_t* s_stateLabel;
static lv_obj_t* s_clockLabel;
static lv_obj_t* s_battLabel;  // between the GPS state and the clock
static lv_obj_t* s_catchesCard;
static lv_obj_t* s_anglerCount[MAX_ANGLERS];  // null past anglers::count()
static lv_obj_t* s_tripDistance;
static lv_obj_t* s_tripTime;
static lv_obj_t* s_speedLabel;
static lv_obj_t* s_courseLabel;     // compass point
static lv_obj_t* s_courseDegLabel;  // degrees
static lv_obj_t* s_satsLabel;
static lv_obj_t* s_hdopLabel;

// Catch banner: the angler's name and new count, over the catches and trip
// cards, for a few seconds. Also used for undo.
static lv_obj_t* s_banner;
static lv_obj_t* s_bannerName;
static lv_obj_t* s_bannerCount;
static lv_obj_t* s_bannerNote;
static uint32_t s_bannerUntil = 0;

// Details page, shown by the BOOT button.
static const int kDetailRows = 11;
static lv_obj_t* s_details;
static lv_obj_t* s_detailValue[kDetailRows];
static uint32_t s_detailsUntil = 0;

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
static lv_color_t anglerColour(int i) { return lv_color_hex(anglers::colourRgb(anglers::get(i).colour)); }

// Setting a style invalidates the object even when the value is unchanged, and
// for the screen-sized boxes that means a full redraw. These only touch the
// style when the colour changes.
static void setBorder(lv_obj_t* obj, lv_color_t c) {
  if (lv_obj_get_style_border_color(obj, LV_PART_MAIN).full != c.full)
    lv_obj_set_style_border_color(obj, c, 0);
}
static void setBgColour(lv_obj_t* obj, lv_color_t c) {
  if (lv_obj_get_style_bg_color(obj, LV_PART_MAIN).full != c.full) lv_obj_set_style_bg_color(obj, c, 0);
}
static void setTextColour(lv_obj_t* obj, lv_color_t c) {
  if (lv_obj_get_style_text_color(obj, LV_PART_MAIN).full != c.full)
    lv_obj_set_style_text_color(obj, c, 0);
}

// lv_label_set_text always invalidates; skip it when nothing changed.
static void setText(lv_obj_t* label, const char* text) {
  if (strcmp(lv_label_get_text(label), text) != 0) lv_label_set_text(label, text);
}

static void setHidden(lv_obj_t* obj, bool hidden) {
  if (lv_obj_has_flag(obj, LV_OBJ_FLAG_HIDDEN) != hidden) {
    if (hidden) lv_obj_add_flag(obj, LV_OBJ_FLAG_HIDDEN);
    else lv_obj_clear_flag(obj, LV_OBJ_FLAG_HIDDEN);
  }
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
                           const char* text = "--", lv_color_t colour = kWhite) {
  lv_obj_t* l = lv_label_create(parent);
  lv_obj_set_style_text_font(l, font, 0);
  lv_obj_set_style_text_color(l, colour, 0);
  lv_label_set_text(l, text);
  lv_obj_align(l, align, x, y);
  return l;
}

static void makeSeparator(lv_obj_t* parent, int y) {
  static lv_point_t pts[] = {{0, 0}, {120, 0}};
  lv_obj_t* line = lv_line_create(parent);
  lv_line_set_points(line, pts, 2);
  lv_obj_set_style_line_color(line, lv_color_hex(0x444444), 0);
  lv_obj_set_style_line_width(line, 2, 0);
  lv_obj_set_style_line_rounded(line, true, 0);
  lv_obj_align(line, LV_ALIGN_TOP_MID, 0, y);
}

// A rounded dark panel that groups related values. Children align inside it.
static lv_obj_t* makeCard(lv_obj_t* parent, int x, int y, int w, int h) {
  lv_obj_t* card = lv_obj_create(parent);
  lv_obj_remove_style_all(card);
  lv_obj_set_size(card, w, h);
  lv_obj_set_pos(card, x, y);
  lv_obj_set_style_radius(card, 12, 0);
  lv_obj_set_style_bg_color(card, lv_color_hex(0x1E1E1E), 0);
  lv_obj_set_style_bg_opa(card, LV_OPA_COVER, 0);
  lv_obj_clear_flag(card, LV_OBJ_FLAG_SCROLLABLE);
  return card;
}

// A transparent row that sizes to its children and keeps them on one
// baseline-ish line, centred where it's aligned: "5.2 km/h" with a small unit.
static lv_obj_t* makeRow(lv_obj_t* parent, int y) {
  lv_obj_t* row = lv_obj_create(parent);
  lv_obj_remove_style_all(row);
  lv_obj_set_size(row, LV_SIZE_CONTENT, LV_SIZE_CONTENT);
  lv_obj_set_flex_flow(row, LV_FLEX_FLOW_ROW);
  lv_obj_set_flex_align(row, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_END, LV_FLEX_ALIGN_END);
  lv_obj_set_style_pad_column(row, 5, 0);
  lv_obj_align(row, LV_ALIGN_TOP_MID, 0, y);
  return row;
}

static lv_obj_t* rowLabel(lv_obj_t* row, const lv_font_t* font, const char* text, lv_color_t colour,
                          int bottomPad = 0) {
  lv_obj_t* l = lv_label_create(row);
  lv_obj_set_style_text_font(l, font, 0);
  lv_obj_set_style_text_color(l, colour, 0);
  lv_obj_set_style_pad_bottom(l, bottomPad, 0);  // lifts a small caption towards the big text's baseline
  lv_label_set_text(l, text);
  return l;
}

// The catches card: one to MAX_ANGLERS anglers, each name in its colour over
// the count. One or two anglers get big digits; three or four a 2 x 2 grid.
static void buildCatches() {
  lv_obj_clean(s_catchesCard);
  for (lv_obj_t*& l : s_anglerCount) l = nullptr;
  int n = anglers::count();
  bool grid = n > 2;
  for (int i = 0; i < n; i++) {
    int x = n == 1 ? 0 : (i % 2 == 0 ? -38 : 38);
    int y = grid ? (i < 2 ? 4 : 46) : 8;
    lv_obj_t* name = makeLabel(s_catchesCard, &lv_font_montserrat_12, LV_ALIGN_TOP_MID, x, y,
                               anglers::get(i).name, anglerColour(i));
    lv_label_set_long_mode(name, LV_LABEL_LONG_DOT);
    lv_obj_set_width(name, n == 1 ? 140 : 72);
    lv_obj_set_style_text_align(name, LV_TEXT_ALIGN_CENTER, 0);
    s_anglerCount[i] = makeLabel(s_catchesCard, grid ? &lv_font_montserrat_28 : &lv_font_montserrat_48,
                                 LV_ALIGN_TOP_MID, x, y + (grid ? 11 : 16), "0");
  }
}

static void buildLogger() {
  s_loggerScreen = lv_obj_create(nullptr);
  s_loggerBox = makeBox(s_loggerScreen);

  // Status strip
  s_stateDot = lv_obj_create(s_loggerBox);
  lv_obj_remove_style_all(s_stateDot);
  lv_obj_set_size(s_stateDot, 9, 9);
  lv_obj_set_style_radius(s_stateDot, LV_RADIUS_CIRCLE, 0);
  lv_obj_set_style_bg_opa(s_stateDot, LV_OPA_COVER, 0);
  lv_obj_set_style_bg_color(s_stateDot, palette(LV_PALETTE_RED), 0);
  lv_obj_align(s_stateDot, LV_ALIGN_TOP_LEFT, 12, 17);
  s_stateLabel = makeLabel(s_loggerBox, &lv_font_montserrat_14, LV_ALIGN_TOP_LEFT, 25, 12, "No GPS");
  s_clockLabel = makeLabel(s_loggerBox, &lv_font_montserrat_14, LV_ALIGN_TOP_RIGHT, -12, 12, "--:--");
  // Centred in the gap between the state ("SD error" is the longest, to x ~81) and the
  // clock (from x ~124): "3.85V" in the 12 px font is about 32 px wide.
  s_battLabel = makeLabel(s_loggerBox, &lv_font_montserrat_12, LV_ALIGN_TOP_MID, 16, 14, "");

  // Cards: catches, trip, then speed and GPS side by side. Positions are inside
  // the box's border; cards are kCardX from each side.
  const int kCardX = 7, kCardW = LCD_WIDTH - 6 - 2 * kCardX, kHalfW = (kCardW - 8) / 2;

  s_catchesCard = makeCard(s_loggerBox, kCardX, 34, kCardW, 88);
  buildCatches();

  lv_obj_t* trip = makeCard(s_loggerBox, kCardX, 128, kCardW, 74);
  makeLabel(trip, &lv_font_montserrat_12, LV_ALIGN_TOP_MID, 0, 6, "Trip", kGrey);
  s_tripDistance = makeLabel(trip, &lv_font_montserrat_28, LV_ALIGN_TOP_MID, 0, 20, "0 m");
  lv_obj_t* waterRow = makeRow(trip, 48);
  s_tripTime = rowLabel(waterRow, &lv_font_montserrat_20, "0:00", kWhite);
  rowLabel(waterRow, &lv_font_montserrat_12, "on water", kGrey, 3);

  lv_obj_t* speed = makeCard(s_loggerBox, kCardX, 208, kHalfW, 100);
  makeLabel(speed, &lv_font_montserrat_12, LV_ALIGN_TOP_MID, 0, 6, "km/h", kGrey);
  s_speedLabel = makeLabel(speed, &lv_font_montserrat_28, LV_ALIGN_TOP_MID, 0, 20, "--");
  s_courseLabel = makeLabel(speed, &lv_font_montserrat_20, LV_ALIGN_TOP_MID, 0, 58, "--");
  s_courseDegLabel = makeLabel(speed, &lv_font_montserrat_14, LV_ALIGN_TOP_MID, 0, 82, "", kGrey);

  lv_obj_t* gpsCard = makeCard(s_loggerBox, kCardX + kHalfW + 8, 208, kHalfW, 100);
  makeLabel(gpsCard, &lv_font_montserrat_12, LV_ALIGN_TOP_MID, 0, 6, "sats", kGrey);
  s_satsLabel = makeLabel(gpsCard, &lv_font_montserrat_28, LV_ALIGN_TOP_MID, 0, 20, "--");
  makeLabel(gpsCard, &lv_font_montserrat_12, LV_ALIGN_TOP_MID, 0, 56, "HDOP", kGrey);
  s_hdopLabel = makeLabel(gpsCard, &lv_font_montserrat_24, LV_ALIGN_TOP_MID, 0, 70, "--");

  // Catch banner, hidden until a button is pressed. It covers the catches and trip cards.
  s_banner = lv_obj_create(s_loggerBox);
  lv_obj_set_size(s_banner, kCardW, 168);
  lv_obj_set_pos(s_banner, kCardX, 34);
  lv_obj_set_style_radius(s_banner, 12, 0);
  lv_obj_set_style_border_width(s_banner, 0, 0);
  lv_obj_set_style_pad_all(s_banner, 0, 0);
  lv_obj_clear_flag(s_banner, LV_OBJ_FLAG_SCROLLABLE);
  s_bannerName = makeLabel(s_banner, &lv_font_montserrat_24, LV_ALIGN_TOP_MID, 0, 18, "");
  lv_label_set_long_mode(s_bannerName, LV_LABEL_LONG_DOT);
  lv_obj_set_width(s_bannerName, kCardW - 12);
  lv_obj_set_style_text_align(s_bannerName, LV_TEXT_ALIGN_CENTER, 0);
  s_bannerCount = makeLabel(s_banner, &lv_font_montserrat_48, LV_ALIGN_CENTER, 0, 0, "");
  s_bannerNote = makeLabel(s_banner, &lv_font_montserrat_16, LV_ALIGN_BOTTOM_MID, 0, -18, "");
  lv_obj_add_flag(s_banner, LV_OBJ_FLAG_HIDDEN);

  // Details page: covers the main screen inside the border while it's shown.
  s_details = lv_obj_create(s_loggerBox);
  lv_obj_remove_style_all(s_details);
  lv_obj_set_size(s_details, LCD_WIDTH - 6, LCD_HEIGHT - 6);
  lv_obj_align(s_details, LV_ALIGN_CENTER, 0, 0);
  lv_obj_set_style_radius(s_details, 22, 0);
  lv_obj_set_style_bg_color(s_details, lv_color_hex(0x000000), 0);
  lv_obj_set_style_bg_opa(s_details, LV_OPA_COVER, 0);
  makeLabel(s_details, &lv_font_montserrat_14, LV_ALIGN_TOP_MID, 0, 10, "Details", kGrey);
  static const char* kCaptions[kDetailRows] = {"Date", "Time",  "Satellites", "HDOP",  "Lat",     "Lon",
                                               "Points today", "Card", "Battery", "Reset", "Firmware"};
  // Each value gets the row's width left over after its caption, right-aligned, and is cut
  // short with "..." rather than drawn over the caption if it's ever too long.
  const lv_coord_t kMargin = 12, kGap = 8;
  const lv_coord_t rowWidth = LCD_WIDTH - 6 - 2 * kMargin;
  for (int i = 0; i < kDetailRows; i++) {
    int y = 38 + i * 24;
    makeLabel(s_details, &lv_font_montserrat_12, LV_ALIGN_TOP_LEFT, kMargin, y + 2, kCaptions[i], kGrey);
    lv_coord_t capW = lv_txt_get_width(kCaptions[i], strlen(kCaptions[i]), &lv_font_montserrat_12, 0,
                                       LV_TEXT_FLAG_NONE);
    lv_obj_t* v = makeLabel(s_details, &lv_font_montserrat_14, LV_ALIGN_TOP_RIGHT, -kMargin, y, "--");
    lv_label_set_long_mode(v, LV_LABEL_LONG_DOT);
    lv_obj_set_width(v, rowWidth - capW - kGap);
    lv_obj_set_style_text_align(v, LV_TEXT_ALIGN_RIGHT, 0);
    s_detailValue[i] = v;
  }
  lv_obj_add_flag(s_details, LV_OBJ_FLAG_HIDDEN);
}

static void buildTransfer() {
  s_transferScreen = lv_obj_create(nullptr);
  s_transferBox = makeBox(s_transferScreen);
  lv_obj_set_style_border_color(s_transferBox, palette(LV_PALETTE_BLUE), 0);

  makeLabel(s_transferBox, &lv_font_montserrat_24, LV_ALIGN_TOP_MID, 0, 16, "Transfer");
  s_bleLabel = makeLabel(s_transferBox, &lv_font_montserrat_14, LV_ALIGN_TOP_MID, 0, 52, "");
  makeSeparator(s_transferBox, 80);

  makeLabel(s_transferBox, &lv_font_montserrat_12, LV_ALIGN_TOP_MID, 0, 90, "File", kGrey);
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
                             "Open the logger page\nin Chrome on Android", kGrey);
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

// ---- Logger screen updates ----

static void formatDistance(double m, char* out, size_t len) {
  if (m < 1000) snprintf(out, len, "%.0f m", m);
  else if (m < 100000) snprintf(out, len, "%.1f km", m / 1000.0);
  else snprintf(out, len, "%.0f km", m / 1000.0);
}

static void refreshDetails(uint32_t nowMs) {
  TinyGPSPlus& gps = gpsrx::parser();
  bool comms = gpsrx::commsOk(nowMs);
  char buf[32];

  if (clk::isSet()) {
    time_t t = clk::now();
    struct tm tm;
    localtime_r(&t, &tm);
    strftime(buf, sizeof(buf), "%a %d %b", &tm);
    setText(s_detailValue[0], buf);
    strftime(buf, sizeof(buf), "%H:%M:%S %Z", &tm);
    setText(s_detailValue[1], buf);
  } else {
    setText(s_detailValue[0], "no GPS time");
    setText(s_detailValue[1], "--");
  }

  if (comms) snprintf(buf, sizeof(buf), "%d of %d", gps.satellitesStats.nrSatsTracked(),
                      gps.satellitesStats.nrSatsVisible());
  else snprintf(buf, sizeof(buf), "--");
  setText(s_detailValue[2], buf);

  if (comms && gps.hdop.isValid()) snprintf(buf, sizeof(buf), "%.1f", gpsrx::hdop());
  else snprintf(buf, sizeof(buf), "--");
  setText(s_detailValue[3], buf);

  if (comms && gps.location.isValid()) {
    snprintf(buf, sizeof(buf), "%.5f", gps.location.lat());
    setText(s_detailValue[4], buf);
    snprintf(buf, sizeof(buf), "%.5f", gps.location.lng());
    setText(s_detailValue[5], buf);
  } else {
    setText(s_detailValue[4], "--");
    setText(s_detailValue[5], "--");
  }

  const DayStats& st = tracklog::stats();
  if (st.known) snprintf(buf, sizeof(buf), "%lu", (unsigned long)st.points);
  else snprintf(buf, sizeof(buf), "--");
  setText(s_detailValue[6], buf);

  if (!storage::mounted()) snprintf(buf, sizeof(buf), "not mounted");
  else if (!tracklog::lastWriteOk()) snprintf(buf, sizeof(buf), "write failed");
  else if (tracklog::buffered()) snprintf(buf, sizeof(buf), "OK, %lu waiting", (unsigned long)tracklog::buffered());
  else snprintf(buf, sizeof(buf), "OK");
  setText(s_detailValue[7], buf);

  uint16_t mv = battery::millivolts();
  switch (battery::source()) {
    case battery::Source::Unknown: snprintf(buf, sizeof(buf), "--"); break;
    case battery::Source::External: snprintf(buf, sizeof(buf), "USB, %.2f V", mv / 1000.0); break;
    case battery::Source::Battery: snprintf(buf, sizeof(buf), "%.2f V", mv / 1000.0); break;
  }
  setText(s_detailValue[8], buf);

  const trip::Meter& tm = trip::meter();
  if (tm.resetUtc) {
    time_t t = tm.resetUtc;
    struct tm lt;
    localtime_r(&t, &lt);
    strftime(buf, sizeof(buf), "%d %b %Y", &lt);
  } else {
    snprintf(buf, sizeof(buf), "never reset");
  }
  setText(s_detailValue[9], buf);
  setText(s_detailValue[10], FW_VERSION);
}

void refreshLogger(uint32_t nowMs, bool) {
  TinyGPSPlus& gps = gpsrx::parser();
  bool comms = gpsrx::commsOk(nowMs);
  bool lock = gpsrx::hasLock(nowMs);
  bool cardOk = storage::mounted() && tracklog::lastWriteOk();
  char buf[40];

  // Health: the border and the strip's dot and words.
  lv_palette_t health;
  if (!cardOk) {
    health = LV_PALETTE_RED;
    snprintf(buf, sizeof(buf), "SD error");
  } else if (!comms) {
    health = LV_PALETTE_RED;
    snprintf(buf, sizeof(buf), "No GPS");
  } else if (!lock) {
    health = LV_PALETTE_ORANGE;
    snprintf(buf, sizeof(buf), "No fix");
  } else {
    health = LV_PALETTE_GREEN;
    snprintf(buf, sizeof(buf), "GPS fix");
  }
  setBorder(s_loggerBox, palette(health));
  setBgColour(s_stateDot, palette(health));
  setText(s_stateLabel, buf);
  setTextColour(s_stateLabel, health == LV_PALETTE_GREEN ? kWhite : palette(health));

  if (clk::isSet()) {
    time_t t = clk::now();
    struct tm tm;
    localtime_r(&t, &tm);
    strftime(buf, sizeof(buf), "%H:%M", &tm);
    setText(s_clockLabel, buf);
  } else {
    setText(s_clockLabel, "--:--");
  }

  // Battery: blank without the divider, "USB" on an external supply, otherwise the
  // cell voltage, orange when low and red when the 3.3 V rail is about to sag.
  uint16_t mv = battery::millivolts();
  lv_color_t battColour = kWhite;
  switch (battery::source()) {
    case battery::Source::Unknown: buf[0] = 0; break;
    case battery::Source::External: snprintf(buf, sizeof(buf), "USB"); battColour = kGrey; break;
    case battery::Source::Battery:
      snprintf(buf, sizeof(buf), "%.2fV", mv / 1000.0);
      if (mv <= BATT_CRITICAL_MV) battColour = palette(LV_PALETTE_RED);
      else if (mv <= BATT_LOW_MV) battColour = palette(LV_PALETTE_ORANGE);
      break;
  }
  setText(s_battLabel, buf);
  setTextColour(s_battLabel, battColour);

  // Trip meter: catches, distance and time on the water since the app last reset it.
  const trip::Meter& tm = trip::meter();
  for (int i = 0; i < MAX_ANGLERS; i++) {
    if (!s_anglerCount[i]) continue;
    snprintf(buf, sizeof(buf), "%lu", (unsigned long)tm.catches[i]);
    setText(s_anglerCount[i], buf);
  }
  char dist[20];
  formatDistance(tm.distanceM, dist, sizeof(dist));
  snprintf(buf, sizeof(buf), "%s%s", dist, tm.complete ? "" : " ?");  // ?: the card couldn't be read
  setText(s_tripDistance, buf);
  unsigned long mins = tm.waterS / 60;
  snprintf(buf, sizeof(buf), "%lu:%02lu", mins / 60, mins % 60);
  setText(s_tripTime, buf);

  // Speed and course: "--" when invalid, stale or the fix isn't good enough.
  bool good = comms && gpsrx::hdop() <= MAX_HDOP;
  if (good && gps.speed.isValid() && gps.speed.age() < 3000) snprintf(buf, sizeof(buf), "%.1f", gps.speed.kmph());
  else snprintf(buf, sizeof(buf), "--");
  setText(s_speedLabel, buf);
  if (good && gps.course.isValid() && gps.course.age() < 3000) {
    double deg = gps.course.deg();
    setText(s_courseLabel, TinyGPSPlus::cardinal(deg));
    snprintf(buf, sizeof(buf), "%.0f\xC2\xB0", deg);  // UTF-8 degree sign
    setText(s_courseDegLabel, buf);
  } else {
    setText(s_courseLabel, "--");
    setText(s_courseDegLabel, "");
  }

  // Satellites and HDOP, with or without a fix, while the GPS is talking. Without a
  // fix the module reports HDOP 99.99, which shows as "--". HDOP is green at 2 or
  // better, white up to MAX_HDOP, and orange above it, where speed and course are
  // hidden and moves aren't counted.
  if (comms) snprintf(buf, sizeof(buf), "%d", gps.satellitesStats.nrSatsTracked());
  else snprintf(buf, sizeof(buf), "--");
  setText(s_satsLabel, buf);
  double hdop = gpsrx::hdop();
  bool hdopKnown = comms && gps.hdop.isValid() && hdop < 99;
  if (hdopKnown) snprintf(buf, sizeof(buf), "%.1f", hdop);
  else snprintf(buf, sizeof(buf), "--");
  setText(s_hdopLabel, buf);
  lv_color_t hdopColour = kWhite;
  if (hdopKnown && hdop > MAX_HDOP) hdopColour = palette(LV_PALETTE_ORANGE);
  else if (hdopKnown && hdop <= 2) hdopColour = palette(LV_PALETTE_GREEN);
  setTextColour(s_hdopLabel, hdopColour);

  if (s_bannerUntil && (int32_t)(nowMs - s_bannerUntil) >= 0) {
    lv_obj_add_flag(s_banner, LV_OBJ_FLAG_HIDDEN);
    s_bannerUntil = 0;
  }
  if (s_detailsUntil) {
    if ((int32_t)(nowMs - s_detailsUntil) >= 0) {
      setHidden(s_details, true);
      s_detailsUntil = 0;
    } else {
      refreshDetails(nowMs);
    }
  }
}

// Shows the banner for angler 'a' with their count now, a note and a colour.
static void showBanner(int a, const char* note, lv_color_t bg, uint32_t nowMs) {
  setHidden(s_details, true);  // a catch always shows on the main screen
  s_detailsUntil = 0;
  char buf[16];
  setText(s_bannerName, anglers::get(a).name);
  snprintf(buf, sizeof(buf), "%lu", (unsigned long)trip::meter().catches[a]);
  setText(s_bannerCount, buf);
  setText(s_bannerNote, note);
  setBgColour(s_banner, bg);
  lv_obj_clear_flag(s_banner, LV_OBJ_FLAG_HIDDEN);
  lv_obj_move_foreground(s_banner);
  s_bannerUntil = nowMs + CATCH_BANNER_MS;
  if (s_bannerUntil == 0) s_bannerUntil = 1;
  refreshLogger(nowMs, true);  // counts update together with the banner
}

void showCatch(int angler, bool savedOk, uint32_t nowMs) {
  showBanner(angler, savedOk ? "saved" : "NOT SAVED", savedOk ? anglerColour(angler) : palette(LV_PALETTE_RED),
             nowMs);
}

void showUndo(int angler, tracklog::UndoResult r, uint32_t nowMs) {
  const lv_color_t grey = lv_color_hex(0x424242);
  switch (r) {
    case tracklog::UndoResult::Undone:
      return showBanner(angler, "undone", grey, nowMs);
    case tracklog::UndoResult::NothingToUndo:
      return showBanner(angler, "nothing to undo", grey, nowMs);
    case tracklog::UndoResult::NotSaved:
      return showBanner(angler, "undo NOT SAVED", palette(LV_PALETTE_RED), nowMs);
  }
}

void anglersChanged() {
  buildCatches();
  setHidden(s_banner, true);  // it may name an angler that's gone
  s_bannerUntil = 0;
}

void showDetails(uint32_t nowMs) {
  if (s_bannerUntil) return;  // let the catch banner finish
  s_detailsUntil = nowMs + DETAILS_PAGE_MS;
  if (s_detailsUntil == 0) s_detailsUntil = 1;
  refreshDetails(nowMs);
  setHidden(s_details, false);
  lv_obj_move_foreground(s_details);
}

// ---- Transfer screen ----

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
