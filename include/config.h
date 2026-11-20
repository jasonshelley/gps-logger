#pragma once
// All pins and tuning constants in one place.
//
// Board: Waveshare ESP32-C6-LCD-1.47. Pin facts are from Waveshare's schematic
// (ESP32-C6-LCD-1.47_schemetics.pdf). Header U2 brings out IO0-IO5, IO9 (BOOT),
// IO18-IO20, IO23, TXD and RXD.
//
// Used on the board itself (don't wire anything else to these):
//   LCD   MOSI 6, SCLK 7, CS 14, DC 15, RST 21, backlight 22
//   SD    CS 4, MISO 5 (MOSI/SCLK shared with the LCD; both have 10k pull-ups)
//   RGB LED 8, BOOT button 9, USB D-/D+ 12/13
// ESP32-C6 strapping pins: 4, 5, 8, 9, 15. GPIO 0/1 can take a 32 kHz crystal,
// but this board doesn't fit one (its only crystal is the 40 MHz on XTAL_P/N).

#include <stdint.h>

// ---- Display (ST7789, 172 x 320) ----
#define PIN_SPI_MOSI      6
#define PIN_SPI_SCLK      7
#define PIN_SPI_MISO      5   // only the SD card drives MISO
#define PIN_LCD_CS        14
#define PIN_LCD_DC        15
#define PIN_LCD_RST       21
#define PIN_LCD_BL        22

// ---- SD card (same SPI bus) ----
#define PIN_SD_CS         4
#define SD_SPI_HZ         20000000

// ---- GPS (UART1, NMEA, 9600 8N1) ----
#define PIN_GPS_RX        19  // ESP RX  <- GPS TX
#define PIN_GPS_TX        18  // ESP TX  -> GPS RX
#define GPS_BAUD          9600

// ---- Buttons and switch: active low to GND, internal pull-ups ----
// GPIO 1-3 are on header U2, have nothing else attached, and aren't strapping pins.
// Catch buttons, in angler order: button 1 is angler 1 (see /anglers.txt).
// More buttons go here when there are pins for them (up to MAX_ANGLERS).
#define ANGLER_BUTTON_PINS { 1, 2 }
// Optional: the old mode switch. Closing or opening it still changes the mode,
// and so does holding BOOT; whichever happened last wins. Without a switch the
// pull-up reads open, so the logger boots in Logging mode.
#define PIN_MODE_SWITCH   3   // LOW (closed to GND) = Transfer, HIGH (open) = Logging
// The board's BOOT button. Held at reset it starts the ROM bootloader; after
// boot it's a plain input (external pull-up): a press wakes the screen and
// shows the details page, a hold switches between Logging and Transfer.
#define PIN_BTN_BOOT      9

#define BUTTON_DEBOUNCE_MS    50
#define BUTTON_HOLD_MS        2000  // a catch button held this long undoes that angler's last catch
#define SWITCH_DEBOUNCE_MS    250
// Transfer mode goes back to Logging after this long without a phone connected,
// so a logger left in Transfer doesn't miss a day's fishing.
#define TRANSFER_IDLE_MS      600000

// ---- Anglers: names and colours, set by the phone app, kept on the card ----
#define MAX_ANGLERS           4
#define ANGLER_NAME_MAX       12
#define ANGLERS_FILE          "/anglers.txt"
#define ANGLERS_TMP_FILE      "/anglers.tmp"

// ---- Fix quality and the log rule (requirements Q6, Q7) ----
#define MAX_HDOP                  5.0   // track points and "has lock" need HDOP <= this
// Log rule. "Moving" means the movement rule (src/move_meter.h, docs/metrics.md)
// confirmed a move in the last LOG_MOVING_HOLD_MS. A fix that completes a move is
// always logged. GPS speed isn't used: indoors it reads several km/h while still.
#define LOG_MIN_INTERVAL_MS       5000  // moving: a point every 5 s
#define LOG_STATIONARY_INTERVAL_MS 60000 // otherwise: one point a minute
#define LOG_MOVING_HOLD_MS        120000
#define LOCK_TIMEOUT_MS           5000  // "has lock" = a good fix within this long
#define GPS_COMMS_TIMEOUT_MS      1000  // "comms OK" = a byte from the GPS within this long

// Track points more than 15 minutes apart are in separate segments (the logger
// was off or had no good fix in between). The movement rule's constants, this
// gap among them, are in src/move_meter.h, since the native tests build that
// file without this one. The phone page splits GPX segments at the same 15 min.

// ---- Trip meter ----
#define TRIP_FILE                 "/trip.txt"
#define TRIP_TMP_FILE             "/trip.tmp"

// ---- Writing to the card (Q5) ----
#define FLUSH_INTERVAL_MS     10000     // buffered track points reach the card every 10 s
#define LOG_BUFFER_ROWS       32        // flushes early if it fills
#define LOG_ROW_MAX           192

// ---- Time zone (Q8): Sydney/Melbourne, AEST/AEDT switch handled by the C library ----
#define LOCAL_TZ              "AEST-10AEDT,M10.1.0,M4.1.0/3"

// ---- Screen ----
#define CATCH_BANNER_MS       3000
#define DETAILS_PAGE_MS       10000     // the BOOT button's details page stays up this long
#define UI_SLOW_REFRESH_MS    1000
#define UI_FAST_REFRESH_MS    500       // logger screen, details page seconds, transfer progress
// The backlight is bright for BACKLIGHT_AWAKE_MS after any button press, a mode
// change or a phone connecting, then dims. It's the biggest load we control.
#define BACKLIGHT_BRIGHT_PERCENT 90
#define BACKLIGHT_DIM_PERCENT    15
#define BACKLIGHT_AWAKE_MS       30000

// ---- Power ----
// 80 MHz is plenty for 1 Hz GPS, a small screen and BLE, and draws less than the default 160.
#define CPU_FREQ_MHZ          80
#define LOOP_IDLE_MS          10        // main loop sleep between passes (1 ms while sending a file)

// ---- Bluetooth LE transfer ----
#define BLE_DEVICE_NAME       "GPS Logger"

// ---- Serial console ----
#define CONSOLE_BAUD          115200
#define CONSOLE_LINE_MAX      96
