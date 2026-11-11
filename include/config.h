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
#define PIN_BTN_JASE      1
#define PIN_BTN_MATT      2
#define PIN_MODE_SWITCH   3   // LOW (closed to GND) = Transfer, HIGH (open) = Logging

#define BUTTON_DEBOUNCE_MS    50
#define SWITCH_DEBOUNCE_MS    250

// ---- Fix quality and the log rule (requirements Q6, Q7) ----
#define MAX_HDOP                  5.0   // track points and "has lock" need HDOP <= this
#define LOG_MIN_INTERVAL_MS       5000  // moving: log at least every 5 s ...
#define LOG_MIN_DISTANCE_M        10.0  // ... or as soon as we've moved 10 m
#define LOG_STATIONARY_INTERVAL_MS 60000 // stationary: one point a minute
#define STATIONARY_SPEED_KMH      2.0   // below this (and < 10 m moved) counts as stationary
#define LOCK_TIMEOUT_MS           5000  // "has lock" = a good fix within this long
#define GPS_COMMS_TIMEOUT_MS      1000  // "comms OK" = a byte from the GPS within this long

// ---- Writing to the card (Q5) ----
#define FLUSH_INTERVAL_MS     10000     // buffered track points reach the card every 10 s
#define LOG_BUFFER_ROWS       32        // flushes early if it fills
#define LOG_ROW_MAX           192

// ---- Time zone (Q8): Sydney/Melbourne, AEST/AEDT switch handled by the C library ----
#define LOCAL_TZ              "AEST-10AEDT,M10.1.0,M4.1.0/3"

// ---- Screen ----
#define CATCH_BANNER_MS       3000
#define UI_SLOW_REFRESH_MS    1000      // satellites, course, speed
#define UI_FAST_REFRESH_MS    200       // clock, status, transfer progress
#define BACKLIGHT_PERCENT     90

// ---- Bluetooth LE transfer ----
#define BLE_DEVICE_NAME       "GPS Logger"

// ---- Serial console ----
#define CONSOLE_BAUD          115200
#define CONSOLE_LINE_MAX      96
