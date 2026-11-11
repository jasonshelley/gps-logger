#include "st7789.h"

#include <Arduino.h>
#include <SPI.h>

#include "config.h"

// Panel RAM is 240 wide; the 172 visible columns start at 34.
static const uint16_t kOffsetX = 34;
static const uint16_t kOffsetY = 0;
static const uint32_t kLcdSpiHz = 80000000;

static const uint32_t kBacklightPwmHz = 1000;
static const uint8_t kBacklightBits = 10;

static inline void beginLcd(bool data) {
  SPI.beginTransaction(SPISettings(kLcdSpiHz, MSBFIRST, SPI_MODE0));
  digitalWrite(PIN_LCD_CS, LOW);
  digitalWrite(PIN_LCD_DC, data ? HIGH : LOW);
}

static inline void endLcd() {
  digitalWrite(PIN_LCD_CS, HIGH);
  SPI.endTransaction();
}

static void writeCommand(uint8_t cmd) {
  beginLcd(false);
  SPI.transfer(cmd);
  endLcd();
}

static void writeData(uint8_t data) {
  beginLcd(true);
  SPI.transfer(data);
  endLcd();
}

static void writeCommandData(uint8_t cmd, const uint8_t* data, size_t len) {
  writeCommand(cmd);
  for (size_t i = 0; i < len; i++) writeData(data[i]);
}

#define CMD(c, ...)                                         \
  do {                                                      \
    static const uint8_t d[] = {__VA_ARGS__};               \
    writeCommandData((c), d, sizeof(d));                    \
  } while (0)

static void lcdReset() {
  digitalWrite(PIN_LCD_CS, LOW);
  delay(50);
  digitalWrite(PIN_LCD_RST, LOW);
  delay(50);
  digitalWrite(PIN_LCD_RST, HIGH);
  delay(50);
}

void lcdSetBacklight(uint8_t percent) {
  if (percent > 100) percent = 100;
  ledcWrite(PIN_LCD_BL, (uint32_t)percent * 10);
}

void lcdInit() {
  pinMode(PIN_LCD_CS, OUTPUT);
  pinMode(PIN_LCD_DC, OUTPUT);
  pinMode(PIN_LCD_RST, OUTPUT);
  // Keep the SD card deselected while the panel initialises.
  pinMode(PIN_SD_CS, OUTPUT);
  digitalWrite(PIN_SD_CS, HIGH);

  ledcAttach(PIN_LCD_BL, kBacklightPwmHz, kBacklightBits);
  lcdSetBacklight(0);

  SPI.begin(PIN_SPI_SCLK, PIN_SPI_MISO, PIN_SPI_MOSI);

  lcdReset();

  writeCommand(0x11);  // sleep out
  delay(120);
  CMD(0x36, 0x00);     // MADCTL: portrait
  CMD(0x3A, 0x05);     // 16-bit RGB565
  CMD(0xB0, 0x00, 0xE8);  // RAMCTRL: little-endian pixel data (matches LV_COLOR_16_SWAP 0)
  CMD(0xB2, 0x0C, 0x0C, 0x00, 0x33, 0x33);
  CMD(0xB7, 0x35);
  CMD(0xBB, 0x35);
  CMD(0xC0, 0x2C);
  CMD(0xC2, 0x01);
  CMD(0xC3, 0x13);
  CMD(0xC4, 0x20);
  CMD(0xC6, 0x0F);
  CMD(0xD0, 0xA4, 0xA1);
  CMD(0xD6, 0xA1);
  CMD(0xE0, 0xF0, 0x00, 0x04, 0x04, 0x04, 0x05, 0x29, 0x33, 0x3E, 0x38, 0x12, 0x12, 0x28, 0x30);
  CMD(0xE1, 0xF0, 0x07, 0x0A, 0x0D, 0x0B, 0x07, 0x28, 0x33, 0x3E, 0x36, 0x14, 0x14, 0x29, 0x32);
  writeCommand(0x21);  // inversion on
  writeCommand(0x11);
  delay(120);
  writeCommand(0x29);  // display on

  lcdSetBacklight(BACKLIGHT_PERCENT);
}

static void setWindow(uint16_t x1, uint16_t y1, uint16_t x2, uint16_t y2) {
  x1 += kOffsetX;
  x2 += kOffsetX;
  y1 += kOffsetY;
  y2 += kOffsetY;
  // Column address set
  writeCommand(0x2A);
  writeData(x1 >> 8);
  writeData(x1 & 0xFF);
  writeData(x2 >> 8);
  writeData(x2 & 0xFF);
  // Row address set
  writeCommand(0x2B);
  writeData(y1 >> 8);
  writeData(y1 & 0xFF);
  writeData(y2 >> 8);
  writeData(y2 & 0xFF);
  writeCommand(0x2C);  // memory write
}

void lcdDrawWindow(uint16_t x1, uint16_t y1, uint16_t x2, uint16_t y2, const uint16_t* pixels) {
  setWindow(x1, y1, x2, y2);
  size_t bytes = (size_t)(x2 - x1 + 1) * (y2 - y1 + 1) * sizeof(uint16_t);
  beginLcd(true);
  // writeBytes sends without reading back, so no receive buffer is needed
  // (the old driver put a full-size receive buffer on the stack).
  SPI.writeBytes((const uint8_t*)pixels, bytes);
  endLcd();
}
