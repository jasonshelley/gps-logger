// ESP32-C6 fishing GPS logger.
// Requirements: docs/requirements.md. Pins and constants: include/config.h.

#include <Arduino.h>

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

static Button s_jase(PIN_BTN_JASE, BUTTON_DEBOUNCE_MS);
static Button s_matt(PIN_BTN_MATT, BUTTON_DEBOUNCE_MS);
static ModeSwitch s_modeSwitch(PIN_MODE_SWITCH, SWITCH_DEBOUNCE_MS);

static uint32_t s_lastSlowUi = 0;
static uint32_t s_lastFastUi = 0;

static void enterMode(Mode m) {
  Serial.printf("[mode] %s\n", modeName(m));
  if (m == Mode::Transfer) {
    tracklog::flush();  // Q5: write on every mode switch
    bletx::start();
  } else {
    bletx::stop();
  }
  ui::showMode(m);
  s_lastSlowUi = s_lastFastUi = 0;  // redraw straight away
}

static void handleCatch(Button& b, Angler who, uint32_t now) {
  if (!b.takePress()) return;
  Serial.printf("[btn] %s pressed\n", tracklog::anglerName(who));
  bool ok = tracklog::logCatch(who, now);
  ui::showCatch(who, ok, now);
}

void setup() {
  // Starting the USB console never waits for a computer to connect.
  console::begin();
  Serial.printf("\nGPS logger starting. Flash %lu MB, free heap %lu bytes\n",
                (unsigned long)(ESP.getFlashChipSize() >> 20), (unsigned long)ESP.getFreeHeap());

  lcdInit();
  lvglInit();

  s_jase.begin();
  s_matt.begin();
  s_modeSwitch.begin();  // reads the switch now, so we boot straight into its mode

  clk::begin();
  storage::begin();
  tracklog::begin();
  trip::begin();  // reads /trip.txt and rebuilds the meter from the logs
  ui::begin(s_modeSwitch.mode());
  gpsrx::begin();

  Serial.printf("[mode] %s at boot\n", modeName(s_modeSwitch.mode()));
  if (s_modeSwitch.mode() == Mode::Transfer) bletx::start();
  Serial.println("Ready. Type 'help' for console commands.");
}

void loop() {
  uint32_t now = millis();

  console::poll(now);
  s_jase.update(now);
  s_matt.update(now);
  s_modeSwitch.update(now);
  if (s_modeSwitch.takeChange()) enterMode(s_modeSwitch.mode());

  // GPS is parsed in both modes so the clock stays right, but only Logging mode logs.
  bool newLocation = gpsrx::poll(now);
  storage::ensureMounted(now);  // retries every few seconds after a card error

  bool fastLoop = false;
  if (s_modeSwitch.mode() == Mode::Logging) {
    if (newLocation) {
      GoodFix fix;
      if (gpsrx::currentGoodFix(fix, now)) tracklog::onLocation(fix, now);
    }
    handleCatch(s_jase, Angler::Jase, now);
    handleCatch(s_matt, Angler::Matt, now);
    tracklog::tick(now);

    bool slow = now - s_lastSlowUi >= UI_SLOW_REFRESH_MS || s_lastSlowUi == 0;
    if (slow || now - s_lastFastUi >= UI_FAST_REFRESH_MS) {
      ui::refreshLogger(now, slow);
      if (slow) s_lastSlowUi = now;
      s_lastFastUi = now;
    }
  } else {
    // Presses in Transfer mode are ignored (logging is off).
    bool jase = s_jase.takePress();
    bool matt = s_matt.takePress();
    if (jase || matt) Serial.println("[btn] ignored in Transfer mode");
    bletx::loop(now);
    fastLoop = bletx::status().sending;
    if (now - s_lastFastUi >= UI_FAST_REFRESH_MS || s_lastFastUi == 0) {
      ui::refreshTransfer(now);
      s_lastFastUi = now;
    }
  }

  lvglTask();
  delay(fastLoop ? 1 : 5);
}
