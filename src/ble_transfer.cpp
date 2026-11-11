#include "ble_transfer.h"

#include <Arduino.h>
#include <NimBLEDevice.h>
#include <SD.h>
#include <freertos/queue.h>

#include "config.h"
#include "clock.h"
#include "crc32.h"
#include "storage.h"
#include "track_logger.h"
#include "trip_meter.h"

namespace bletx {

// ---- Protocol constants (see docs/ble-protocol.md) ----
static const char* kServiceUuid = "1f5f0001-56c8-49fb-9d0c-055269d0a2e3";
static const char* kRxUuid = "1f5f0002-56c8-49fb-9d0c-055269d0a2e3";  // phone -> device (write)
static const char* kTxUuid = "1f5f0003-56c8-49fb-9d0c-055269d0a2e3";  // device -> phone (notify)

// v2 added METER and METER_RESET; v3 added ERASE_LOGS. Earlier messages are unchanged.
static const uint8_t kProtocolVersion = 3;

// ERASE_LOGS must carry these four bytes, "ERAS", so a stray write can't erase anything.
static const uint8_t kEraseMagic[4] = {'E', 'R', 'A', 'S'};

enum : uint8_t {
  CMD_HELLO = 0x01,
  CMD_LIST = 0x02,
  CMD_GET = 0x03,
  CMD_CONFIRM = 0x04,
  CMD_ABORT = 0x05,
  CMD_METER = 0x06,        // v2
  CMD_METER_RESET = 0x07,  // v2
  CMD_ERASE_LOGS = 0x08,   // v3

  EVT_HELLO = 0x81,
  EVT_FILE = 0x82,
  EVT_LIST_END = 0x83,
  EVT_BEGIN = 0x84,
  EVT_END = 0x85,
  EVT_CONFIRMED = 0x86,
  EVT_METER = 0x87,        // v2
  EVT_ERASED = 0x88,       // v3
  EVT_DATA = 0x90,
  EVT_ERROR = 0xEE,
};

enum : uint8_t {
  ERR_UNKNOWN_COMMAND = 1,
  ERR_BAD_NAME = 2,
  ERR_NOT_FOUND = 3,
  ERR_BUSY = 4,
  ERR_SD = 5,
  ERR_READ = 6,
  ERR_CRC_MISMATCH = 7,
  ERR_MOVE_FAILED = 8,
  ERR_BAD_LENGTH = 9,
  ERR_BAD_MAGIC = 10,      // v3: ERASE_LOGS without the right confirmation bytes
};

static const size_t kMaxCmd = 96;
static const size_t kMaxChunk = 240;  // payload bytes per DATA notification at most

struct Cmd {
  uint8_t len;
  uint8_t data[kMaxCmd];
};

// ---- State shared with NimBLE callbacks (host task) ----
static QueueHandle_t s_cmdQueue = nullptr;
static volatile bool s_connected = false;
static volatile uint16_t s_connHandle = BLE_HS_CONN_HANDLE_NONE;
static volatile uint16_t s_mtu = 23;

// ---- Main-task state ----
static bool s_initialised = false;
static NimBLEServer* s_server = nullptr;
static NimBLECharacteristic* s_tx = nullptr;
static Status s_status;

static File s_file;
static uint32_t s_crc = 0;
static uint8_t s_pending[5 + kMaxChunk];  // a chunk waiting for a free notify buffer
static size_t s_pendingLen = 0;
static uint32_t s_pendingBytes = 0;       // file bytes in s_pending

// The CRC of the last file sent in full, so CONFIRM needn't reread it.
static char s_doneName[32] = "";
static uint32_t s_doneSize = 0, s_doneCrc = 0;

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer*, NimBLEConnInfo& info) override {
    s_connHandle = info.getConnHandle();
    s_mtu = info.getMTU();
    s_connected = true;
  }
  void onDisconnect(NimBLEServer*, NimBLEConnInfo&, int) override {
    s_connected = false;
    s_connHandle = BLE_HS_CONN_HANDLE_NONE;
    // NimBLE restarts advertising itself (advertiseOnDisconnect defaults to on).
  }
  void onMTUChange(uint16_t mtu, NimBLEConnInfo&) override { s_mtu = mtu; }
};

class RxCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c, NimBLEConnInfo&) override {
    const NimBLEAttValue& v = c->getValue();
    Cmd cmd;
    cmd.len = (uint8_t)(v.size() < kMaxCmd ? v.size() : kMaxCmd);
    memcpy(cmd.data, v.data(), cmd.len);
    xQueueSend(s_cmdQueue, &cmd, 0);  // drop if the main task is far behind
  }
};

// ---- Helpers ----

static void put32(uint8_t* p, uint32_t v) {
  p[0] = v;
  p[1] = v >> 8;
  p[2] = v >> 16;
  p[3] = v >> 24;
}

static uint32_t get32(const uint8_t* p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

// Sends an event, retrying briefly if NimBLE is out of buffers.
static bool sendEvent(const uint8_t* data, size_t len) {
  if (!s_connected || !s_tx) return false;
  for (int i = 0; i < 50; i++) {
    if (s_tx->notify(data, len, s_connHandle)) return true;
    if (!s_connected) return false;
    delay(2);
  }
  Serial.println("[ble] notify failed");
  return false;
}

static void sendError(uint8_t code, const char* text) {
  uint8_t buf[64];
  buf[0] = EVT_ERROR;
  buf[1] = code;
  size_t n = strnlen(text, sizeof(buf) - 2);
  memcpy(buf + 2, text, n);
  sendEvent(buf, n + 2);
  Serial.printf("[ble] error %u: %s\n", code, text);
}

// Event with a u32 and a name: FILE and BEGIN.
static void sendSizeName(uint8_t op, uint32_t size, const char* name) {
  uint8_t buf[5 + 32];
  buf[0] = op;
  put32(buf + 1, size);
  size_t n = strnlen(name, 32);
  memcpy(buf + 5, name, n);
  sendEvent(buf, 5 + n);
}

// Validates a file name sent by the phone: a root-level log file, no path.
static bool readName(const uint8_t* p, size_t len, char* out, size_t outLen) {
  if (len == 0 || len >= outLen) return false;
  memcpy(out, p, len);
  out[len] = 0;
  for (size_t i = 0; i < len; i++) {
    char c = out[i];
    if (c == '/' || c == '\\' || c < 0x20 || c > 0x7E) return false;
  }
  return strstr(out, "..") == nullptr && storage::isLogFileName(out);
}

static void countFilesLeft() {
  s_status.filesLeft = storage::listFiles("/", true, [](const char*, size_t) {});
}

static void closeTransfer() {
  if (s_file) s_file.close();
  s_status.sending = false;
  s_pendingLen = 0;
  s_pendingBytes = 0;
}

static size_t chunkSize() {
  // ATT notification payload is MTU - 3; DATA adds 5 bytes of header.
  int c = (int)s_mtu - 3 - 5;
  if (c < 1) c = 1;
  return (size_t)c < kMaxChunk ? (size_t)c : kMaxChunk;
}

// ---- Command handlers ----

static void handleHello() {
  uint8_t buf[4];
  buf[0] = EVT_HELLO;
  buf[1] = kProtocolVersion;
  uint16_t cs = (uint16_t)chunkSize();
  buf[2] = cs & 0xFF;
  buf[3] = cs >> 8;
  sendEvent(buf, sizeof(buf));
}

static void handleList() {
  if (!storage::ensureMounted(millis())) return sendError(ERR_SD, "SD card not available");
  int n = storage::listFiles("/", true, [](const char* name, size_t size) {
    sendSizeName(EVT_FILE, (uint32_t)size, name);
  });
  if (n < 0) {
    storage::markFailed();
    return sendError(ERR_SD, "Can't read the card");
  }
  s_status.filesLeft = n;
  uint8_t buf[3] = {EVT_LIST_END, (uint8_t)(n & 0xFF), (uint8_t)(n >> 8)};
  sendEvent(buf, sizeof(buf));
}

static void handleGet(const uint8_t* arg, size_t len) {
  char name[32];
  if (!readName(arg, len, name, sizeof(name))) return sendError(ERR_BAD_NAME, "Bad file name");
  if (!storage::ensureMounted(millis())) return sendError(ERR_SD, "SD card not available");
  char path[40];
  snprintf(path, sizeof(path), "/%s", name);
  s_file = SD.open(path, FILE_READ);
  if (!s_file) return sendError(ERR_NOT_FOUND, "File not found");

  snprintf(s_status.file, sizeof(s_status.file), "%s", name);
  s_status.size = s_file.size();
  s_status.sent = 0;
  s_status.sending = true;
  s_crc = 0;
  s_pendingLen = 0;
  snprintf(s_status.lastMsg, sizeof(s_status.lastMsg), "Sending %s", name);
  Serial.printf("[ble] sending %s (%lu bytes)\n", name, (unsigned long)s_status.size);
  sendSizeName(EVT_BEGIN, s_status.size, name);
}

static bool fileCrc(const char* name, uint32_t& size, uint32_t& crc) {
  char path[40];
  snprintf(path, sizeof(path), "/%s", name);
  File f = SD.open(path, FILE_READ);
  if (!f) return false;
  size = f.size();
  crc = 0;
  uint8_t buf[512];
  size_t n;
  while ((n = f.read(buf, sizeof(buf))) > 0) crc = crc32Update(crc, buf, n);
  f.close();
  return true;
}

static void handleConfirm(const uint8_t* arg, size_t len) {
  if (len < 5) return sendError(ERR_BAD_LENGTH, "CONFIRM needs crc + name");
  uint32_t phoneCrc = get32(arg);
  char name[32];
  if (!readName(arg + 4, len - 4, name, sizeof(name))) return sendError(ERR_BAD_NAME, "Bad file name");
  if (s_status.sending && strcmp(name, s_status.file) == 0) return sendError(ERR_BUSY, "Still sending that file");
  if (!storage::ensureMounted(millis())) return sendError(ERR_SD, "SD card not available");

  // Use the CRC from the send if it's the file just sent and its size hasn't
  // changed (nothing writes log files in Transfer mode); otherwise reread it.
  uint32_t size = 0, crc = 0;
  char path[40];
  snprintf(path, sizeof(path), "/%s", name);
  File f = SD.open(path, FILE_READ);
  if (!f) return sendError(ERR_NOT_FOUND, "File not found");
  size = f.size();
  f.close();
  if (strcmp(name, s_doneName) == 0 && size == s_doneSize) {
    crc = s_doneCrc;
  } else if (!fileCrc(name, size, crc)) {
    return sendError(ERR_READ, "Read failed");
  }

  if (crc != phoneCrc) return sendError(ERR_CRC_MISMATCH, "CRC doesn't match; file kept");
  if (!storage::moveToUploaded(name)) {
    storage::markFailed();
    return sendError(ERR_MOVE_FAILED, "Couldn't move to /uploaded");
  }
  Serial.printf("[ble] %s confirmed, moved to " UPLOADED_DIR "\n", name);
  s_doneName[0] = 0;
  snprintf(s_status.lastMsg, sizeof(s_status.lastMsg), "Saved %s", name);
  countFilesLeft();

  uint8_t buf[1 + 32];
  buf[0] = EVT_CONFIRMED;
  size_t n = strnlen(name, 32);
  memcpy(buf + 1, name, n);
  sendEvent(buf, 1 + n);
}

// METER: reset:u32, jase:u16, matt:u16, distance_m:u32, water_s:u32, flags:u8
static void sendMeter() {
  const trip::Meter& m = trip::meter();
  uint8_t buf[18];
  buf[0] = EVT_METER;
  put32(buf + 1, (uint32_t)m.resetUtc);
  uint16_t j = m.jase > 0xFFFF ? 0xFFFF : (uint16_t)m.jase;
  uint16_t t = m.matt > 0xFFFF ? 0xFFFF : (uint16_t)m.matt;
  buf[5] = j & 0xFF;
  buf[6] = j >> 8;
  buf[7] = t & 0xFF;
  buf[8] = t >> 8;
  put32(buf + 9, (uint32_t)(m.distanceM + 0.5));
  put32(buf + 13, m.waterS);
  uint8_t flags = 0;
  if (!m.complete) flags |= 0x01;   // card couldn't be read; the numbers may be short
  if (!clk::isSet()) flags |= 0x02; // the logger hasn't had GPS time since boot
  buf[17] = flags;
  sendEvent(buf, sizeof(buf));
}

static void handleMeterReset(const uint8_t* arg, size_t len) {
  if (len < 4) return sendError(ERR_BAD_LENGTH, "METER_RESET needs a u32 time");
  if (s_status.sending) return sendError(ERR_BUSY, "Busy sending");
  uint32_t t = get32(arg);
  tracklog::flush();  // the rebuild reads the files, so they must hold every row
  trip::ResetResult r = trip::reset((time_t)t);
  if (r == trip::ResetResult::SaveFailed) return sendError(ERR_SD, "Couldn't save the trip reset");
  if (r == trip::ResetResult::Applied) snprintf(s_status.lastMsg, sizeof(s_status.lastMsg), "Trip reset");
  sendMeter();
}

static void put16(uint8_t* p, int v) {
  uint16_t u = v < 0 ? 0 : v > 0xFFFF ? 0xFFFF : (uint16_t)v;
  p[0] = u & 0xFF;
  p[1] = u >> 8;
}

// ERASE_LOGS "ERAS": deletes every log file, zeroes the trip meter.
// Replies ERASED (deleted:u16, failed:u16, flags:u8), then METER.
static void handleEraseLogs(const uint8_t* arg, size_t len) {
  if (len < 4) return sendError(ERR_BAD_LENGTH, "ERASE_LOGS needs the 4-byte code");
  if (memcmp(arg, kEraseMagic, 4) != 0) return sendError(ERR_BAD_MAGIC, "Wrong erase code; nothing erased");
  if (s_status.sending) return sendError(ERR_BUSY, "Busy sending");
  tracklog::EraseResult r = tracklog::eraseAllLogs();
  if (!r.cardOk) return sendError(ERR_SD, "SD card not available; nothing erased");
  s_doneName[0] = 0;
  countFilesLeft();
  snprintf(s_status.lastMsg, sizeof(s_status.lastMsg), "Erased %d log file(s)", r.deleted);
  uint8_t buf[6];
  buf[0] = EVT_ERASED;
  put16(buf + 1, r.deleted);
  put16(buf + 3, r.failed);
  buf[5] = r.tripSaved ? 0 : 0x01;  // bit 0: /trip.txt couldn't be written
  sendEvent(buf, sizeof(buf));
  sendMeter();
}

static void handleCommand(const Cmd& c) {
  if (c.len == 0) return;
  const uint8_t* arg = c.data + 1;
  size_t argLen = c.len - 1;
  switch (c.data[0]) {
    case CMD_HELLO:
      return handleHello();
    case CMD_LIST:
      if (s_status.sending) return sendError(ERR_BUSY, "Busy sending");
      return handleList();
    case CMD_GET:
      if (s_status.sending) return sendError(ERR_BUSY, "Busy sending");
      return handleGet(arg, argLen);
    case CMD_CONFIRM:
      return handleConfirm(arg, argLen);
    case CMD_METER:
      return sendMeter();
    case CMD_METER_RESET:
      return handleMeterReset(arg, argLen);
    case CMD_ERASE_LOGS:
      return handleEraseLogs(arg, argLen);
    case CMD_ABORT:
      if (s_status.sending) {
        closeTransfer();
        snprintf(s_status.lastMsg, sizeof(s_status.lastMsg), "Cancelled");
      }
      return;
    default:
      return sendError(ERR_UNKNOWN_COMMAND, "Unknown command");
  }
}

// Sends as many DATA chunks as NimBLE will take right now, then END.
static void pumpTransfer() {
  if (!s_status.sending) return;
  for (int burst = 0; burst < 16; burst++) {
    if (s_pendingLen == 0) {
      if (s_status.sent >= s_status.size) break;
      size_t want = chunkSize();
      s_pending[0] = EVT_DATA;
      put32(s_pending + 1, s_status.sent);
      int n = s_file.read(s_pending + 5, want);
      if (n <= 0) {
        closeTransfer();
        storage::markFailed();
        snprintf(s_status.lastMsg, sizeof(s_status.lastMsg), "Read error");
        return sendError(ERR_READ, "Read failed");
      }
      s_crc = crc32Update(s_crc, s_pending + 5, n);
      s_pendingLen = 5 + n;
      s_pendingBytes = n;
    }
    if (!s_tx->notify(s_pending, s_pendingLen, s_connHandle)) return;  // out of buffers; retry next pass
    s_status.sent += s_pendingBytes;
    s_pendingLen = 0;
  }

  if (s_pendingLen == 0 && s_status.sent >= s_status.size) {
    uint8_t buf[9];
    buf[0] = EVT_END;
    put32(buf + 1, s_status.size);
    put32(buf + 5, s_crc);
    snprintf(s_doneName, sizeof(s_doneName), "%s", s_status.file);
    s_doneSize = s_status.size;
    s_doneCrc = s_crc;
    closeTransfer();
    snprintf(s_status.lastMsg, sizeof(s_status.lastMsg), "Sent %s", s_status.file);
    Serial.printf("[ble] sent %s, crc %08lx\n", s_status.file, (unsigned long)s_doneCrc);
    sendEvent(buf, sizeof(buf));
  }
}

// ---- Public ----

static void initBle() {
  s_cmdQueue = xQueueCreate(8, sizeof(Cmd));
  NimBLEDevice::init(BLE_DEVICE_NAME);
  NimBLEDevice::setMTU(247);  // a 240-byte chunk + headers fits; Chrome on Android accepts this
  s_server = NimBLEDevice::createServer();
  s_server->setCallbacks(new ServerCallbacks());
  s_server->advertiseOnDisconnect(true);

  NimBLEService* svc = s_server->createService(kServiceUuid);
  NimBLECharacteristic* rx =
      svc->createCharacteristic(kRxUuid, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR, kMaxCmd);
  rx->setCallbacks(new RxCallbacks());
  s_tx = svc->createCharacteristic(kTxUuid, NIMBLE_PROPERTY::NOTIFY, 5 + kMaxChunk);
  // NimBLE 2.x starts the GATT server (and its services) when advertising starts.

  // 128-bit UUID in the advert (so the page can filter on it), name in the scan response.
  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  NimBLEAdvertisementData advData;
  advData.setFlags(BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP);
  advData.setCompleteServices(NimBLEUUID(kServiceUuid));
  NimBLEAdvertisementData scanData;
  scanData.setName(BLE_DEVICE_NAME);
  adv->setAdvertisementData(advData);
  adv->setScanResponseData(scanData);
  adv->enableScanResponse(true);
  s_initialised = true;
}

void start() {
  if (!s_initialised) initBle();
  countFilesLeft();
  if (!NimBLEDevice::getAdvertising()->isAdvertising()) NimBLEDevice::startAdvertising();
  s_status.advertising = true;
  Serial.println("[ble] advertising");
}

void stop() {
  if (!s_initialised) return;
  closeTransfer();
  s_server->advertiseOnDisconnect(false);
  NimBLEDevice::stopAdvertising();
  if (s_connected) s_server->disconnect(s_connHandle);
  s_server->advertiseOnDisconnect(true);
  xQueueReset(s_cmdQueue);
  s_status.advertising = false;
  s_status.connected = false;
  Serial.println("[ble] stopped");
}

void loop(uint32_t) {
  if (!s_initialised) return;
  bool wasConnected = s_status.connected;
  s_status.connected = s_connected;
  if (wasConnected && !s_connected) {
    if (s_status.sending) snprintf(s_status.lastMsg, sizeof(s_status.lastMsg), "Disconnected mid-file");
    closeTransfer();
    xQueueReset(s_cmdQueue);
    Serial.println("[ble] phone disconnected");
  } else if (!wasConnected && s_connected) {
    Serial.println("[ble] phone connected");
  }
  if (!s_connected) return;

  Cmd c;
  // Don't start a new command while a file is streaming, except ABORT/CONFIRM,
  // which handleCommand deals with.
  while (xQueueReceive(s_cmdQueue, &c, 0) == pdTRUE) handleCommand(c);
  pumpTransfer();
}

const Status& status() { return s_status; }

}  // namespace bletx
