#include "storage.h"

#include <SD.h>
#include <SPI.h>

#include "config.h"

namespace storage {

static bool s_mounted = false;
static uint32_t s_lastAttemptMs = 0;
static const uint32_t kRetryMs = 5000;

static bool mount() {
  s_lastAttemptMs = millis();
  if (!SD.begin(PIN_SD_CS, SPI, SD_SPI_HZ)) {
    Serial.println("[sd] mount failed");
    SD.end();
    s_mounted = false;
    return false;
  }
  if (SD.cardType() == CARD_NONE) {
    Serial.println("[sd] no card");
    SD.end();
    s_mounted = false;
    return false;
  }
  s_mounted = true;
  Serial.printf("[sd] mounted, %llu MB, %llu MB used\n", SD.totalBytes() >> 20,
                SD.usedBytes() >> 20);
  return true;
}

bool begin() {
  if (!mount()) return false;
  File f = SD.open("/readme.txt", FILE_READ);
  if (f) {
    Serial.println("[sd] readme.txt:");
    uint8_t buf[64];
    size_t n;
    while ((n = f.read(buf, sizeof(buf))) > 0) Serial.write(buf, n);
    Serial.println();
    f.close();
  }
  return true;
}

bool mounted() { return s_mounted; }

bool ensureMounted(uint32_t nowMs) {
  if (s_mounted) return true;
  if (nowMs - s_lastAttemptMs < kRetryMs) return false;
  return mount();
}

void markFailed() {
  if (!s_mounted) return;
  Serial.println("[sd] I/O error, will remount");
  SD.end();
  s_mounted = false;
  s_lastAttemptMs = millis();
}

bool isLogFileName(const char* name) {
  size_t n = strlen(name);
  return n > 7 && strncasecmp(name, "gps", 3) == 0 && strcasecmp(name + n - 4, ".csv") == 0;
}

static const char* baseName(const char* path) {
  const char* slash = strrchr(path, '/');
  return slash ? slash + 1 : path;
}

int listFiles(const char* dir, bool logOnly, const std::function<void(const char*, size_t)>& fn) {
  if (!s_mounted) return -1;
  File root = SD.open(dir);
  if (!root || !root.isDirectory()) {
    if (root) root.close();
    return -1;
  }
  int count = 0;
  for (File e = root.openNextFile(); e; e = root.openNextFile()) {
    if (!e.isDirectory()) {
      const char* name = baseName(e.name());
      if (!logOnly || isLogFileName(name)) {
        fn(name, e.size());
        count++;
      }
    }
    e.close();
  }
  root.close();
  return count;
}

void absPath(const char* in, char* out, size_t len) {
  if (in[0] == '/')
    snprintf(out, len, "%s", in);
  else
    snprintf(out, len, "/%s", in);
}

bool moveToUploaded(const char* name) {
  if (!s_mounted) return false;
  char src[64], dst[80];
  snprintf(src, sizeof(src), "/%s", name);
  snprintf(dst, sizeof(dst), UPLOADED_DIR "/%s", name);
  if (!SD.exists(src)) return false;
  if (!SD.exists(UPLOADED_DIR) && !SD.mkdir(UPLOADED_DIR)) return false;

  if (!SD.exists(dst)) return SD.rename(src, dst);

  // Append, skipping the source's header line.
  File in = SD.open(src, FILE_READ);
  File out = SD.open(dst, FILE_APPEND);
  if (!in || !out) {
    if (in) in.close();
    if (out) out.close();
    return false;
  }
  bool skipping = true;
  bool ok = true;
  uint8_t buf[512];
  size_t n;
  while ((n = in.read(buf, sizeof(buf))) > 0) {
    size_t start = 0;
    if (skipping) {
      while (start < n && buf[start] != '\n') start++;
      if (start < n) {
        start++;  // past the newline
        skipping = false;
      } else {
        continue;  // header longer than this chunk
      }
    }
    if (start < n && out.write(buf + start, n - start) != n - start) {
      ok = false;
      break;
    }
  }
  in.close();
  out.close();
  return ok && SD.remove(src);
}

uint64_t totalBytes() { return s_mounted ? SD.totalBytes() : 0; }
uint64_t usedBytes() { return s_mounted ? SD.usedBytes() : 0; }

}  // namespace storage
