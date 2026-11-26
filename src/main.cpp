// ESP32-C6 fishing GPS logger.
// Requirements: docs/requirements.md. Pins and constants: include/config.h.

#include <Arduino.h>

#include "anglers.h"
#include "battery.h"
#include "ble_transfer.h"
#include "clock.h"
#include "config.h"
#include "console.h"
#include "gps.h"
#include "inputs.h"
#include "lvgl_port.h"
#include "st7789.h"
#include "storage.h"
#include "track_logger.h"
#include "trip_meter.h"
#include "ui.h"

// Catch buttons, in angler order. Press: a catch. Hold: undo that angler's last catch.
static const uint8_t kButtonPins[] = ANGLER_BUTTON_PINS;
static const int kButtons = sizeof(kButtonPins) / sizeof(kButtonPins[0]);
static_assert(kButtons <= MAX_ANGLERS, "more catch buttons than anglers");
static Button* s_catchButtons[kButtons];

// BOOT: press for the details page, hold to switch between Logging and Transfer.
static Button s_boot(PIN_BTN_BOOT, BUTTON_DEBOUNCE_MS, BUTTON_HOLD_MS);
static ModeSwitch s_modeSwitch(PIN_MODE_SWITCH, SWITCH_DEBOUNCE_MS);
static Mode s_mode = Mode::Logging;
static uint32_t s_transferActiveAt = 0;  // entering Transfer, or the phone last connected

static uint32_t s_lastSlowUi = 0;
static uint32_t s_lastFastUi = 0;

// ---- Backlight: bright for a while after something happens, dim otherwise ----
static uint32_t s_awakeUntil = 0;
static uint8_t s_backlight = BACKLIGHT_BRIGHT_PERCENT;  // lcdInit() leaves it bright

static void wakeScreen(uint32_t now) { s_awakeUntil = now + BACKLIGHT_AWAKE_MS; }

static void updateBacklight(uint32_t now) {
  uint8_t want = (int32_t)(s_awakeUntil - now) > 0 ? BACKLIGHT_BRIGHT_PERCENT : BACKLIGHT_DIM_PERCENT;
  if (want != s_backlight) {
    lcdSetBacklight(want);
    s_backlight = want;
  }
}

static void enterMode(Mode m, const char* why) {
  if (m == s_mode) return;
  s_mode = m;
  Serial.printf("[mode] %s (%s)\n", modeName(m), why);
  if (m == Mode::Transfer) {
    tracklog::flush();  // Q5: write on every mode switch
    bletx::start();
    s_transferActiveAt = millis();
  } else {
    bletx::stop();
  }
  ui::showMode(m);
  s_lastSlowUi = s_lastFastUi = 0;  // redraw straight away
  wakeScreen(millis());
}

static void handleCatchButton(int i, uint32_t now) {
  Button& b = *s_catchButtons[i];
  bool press = b.takePress(), hold = b.takeHold();
  if (!press && !hold) return;
  wakeScreen(now);
  if (i >= anglers::count()) {
    Serial.printf("[btn] button %d has no angler\n", i + 1);
    return;
  }
  if (press) {
    Serial.printf("[btn] %s pressed\n", anglers::get(i).name);
    bool ok = tracklog::logCatch(i, now);
    ui::showCatch(i, ok, now);
  } else {
    Serial.printf("[btn] %s held: undo\n", anglers::get(i).name);
    ui::showUndo(i, tracklog::logUndo(i, now), now);
  }
}

void setup() {
  setCpuFrequencyMhz(CPU_FREQ_MHZ);  // before anything sets up clocks or baud rates
  // Starting the USB console never waits for a computer to connect.
  console::begin();
  Serial.printf("\nGPS logger starting. Flash %lu MB, free heap %lu bytes\n",
                (unsigned long)(ESP.getFlashChipSize() >> 20), (unsigned long)ESP.getFreeHeap());

  lcdInit();
  lvglInit();

  for (int i = 0; i < kButtons; i++) {
    s_catchButtons[i] = new Button(kButtonPins[i], BUTTON_DEBOUNCE_MS, BUTTON_HOLD_MS);
    s_catchButtons[i]->begin();
  }
  s_modeSwitch.begin();  // reads the switch now, so we boot straight into its mode
  s_mode = s_modeSwitch.mode();
  s_boot.begin();

  battery::begin();
  clk::begin();
  storage::begin();
  anglers::begin();  // before the meters, which count catches by angler name
  tracklog::begin();
  trip::begin();  // reads /trip.txt and rebuilds the meter from the logs
  ui::begin(s_mode);
  gpsrx::begin();

  Serial.printf("[mode] %s at boot\n", modeName(s_mode));
  if (s_mode == Mode::Transfer) {
    bletx::start();
    s_transferActiveAt = millis();
  }
  wakeScreen(millis());
  Serial.printf("CPU %lu MHz. Ready. Type 'help' for console commands.\n", (unsigned long)getCpuFrequencyMhz());
}

void loop() {
  uint32_t now = millis();

  console::poll(now);
  battery::poll(now);
  for (Button* b : s_catchButtons) b->update(now);
  s_modeSwitch.update(now);
  s_boot.update(now);

  // The mode follows whichever happened last: the switch moving, or BOOT held.
  if (s_modeSwitch.takeChange()) enterMode(s_modeSwitch.mode(), "switch");
  if (s_boot.takeHold())
    enterMode(s_mode == Mode::Logging ? Mode::Transfer : Mode::Logging, "BOOT held");
  if (s_boot.takePress()) {
    wakeScreen(now);
    if (s_mode == Mode::Logging) ui::showDetails(now);
  }

  // The anglers were read with the card missing; the card is back.
  if (anglers::reloadIfNeeded()) {
    tracklog::anglersChanged();
    trip::rebuildNow();
    ui::anglersChanged();
  }

  // GPS is parsed in both modes so the clock stays right, but only Logging mode logs.
  bool newLocation = gpsrx::poll(now);
  storage::ensureMounted(now);  // retries every few seconds after a card error

  bool fastLoop = false;
  if (s_mode == Mode::Logging) {
    if (newLocation) {
      GoodFix fix;
      if (gpsrx::currentGoodFix(fix, now)) tracklog::onLocation(fix, now);
    }
    for (int i = 0; i < kButtons; i++) handleCatchButton(i, now);
    tracklog::tick(now);

    bool slow = now - s_lastSlowUi >= UI_SLOW_REFRESH_MS || s_lastSlowUi == 0;
    if (slow || now - s_lastFastUi >= UI_FAST_REFRESH_MS) {
      ui::refreshLogger(now, slow);
      if (slow) s_lastSlowUi = now;
      s_lastFastUi = now;
    }
  } else {
    // Presses in Transfer mode are ignored (logging is off).
    bool any = false;
    for (Button* b : s_catchButtons) any |= b->takePress() | b->takeHold();
    if (any) {
      Serial.println("[btn] ignored in Transfer mode");
      wakeScreen(now);
    }
    bletx::loop(now);
    if (bletx::anglersChanged()) {
      tracklog::anglersChanged();
      ui::anglersChanged();
    }
    fastLoop = bletx::status().sending;
    if (bletx::status().connected) {
      wakeScreen(now);  // stay readable while the phone is talking to us
      s_transferActiveAt = now;
    }
    // Signed: s_transferActiveAt can be a millisecond after 'now' when enterMode() set it this pass.
    if ((int32_t)(now - s_transferActiveAt) >= (int32_t)TRANSFER_IDLE_MS)
      enterMode(Mode::Logging, "no phone for 10 min");
    if (now - s_lastFastUi >= UI_FAST_REFRESH_MS || s_lastFastUi == 0) {
      ui::refreshTransfer(now);
      s_lastFastUi = now;
    }
  }

  updateBacklight(now);
  lvglTask();
  delay(fastLoop ? 1 : LOOP_IDLE_MS);
}
