#include "console.h"

#include <Arduino.h>
#include <SD.h>

#include "clock.h"
#include "config.h"
#include "gps.h"
#include "storage.h"
#include "track_logger.h"
#include "trip_meter.h"

namespace console {

static char s_line[CONSOLE_LINE_MAX + 1];
static size_t s_len = 0;
static bool s_overflow = false;
static bool s_awaitConfirmRmAll = false;

static void printHelp() {
  Serial.println(
      "Commands:\n"
      "  help                 this list\n"
      "  status               GPS, clock, card and today's numbers\n"
      "  ls [/uploaded]       list files in / (or /uploaded) with sizes\n"
      "  cat <file>           print a file\n"
      "  tail <file> [n]      print the last n lines (default 10)\n"
      "  rm <file>            delete a file\n"
      "  rm *                 delete every file in / except readme.txt and trip.txt (asks first)\n"
      "  df                   card size and free space\n"
      "Files without a leading / are in the root folder.");
}

static bool needCard() {
  if (storage::ensureMounted(millis())) return true;
  Serial.println("SD card not available");
  return false;
}

static void cmdStatus() {
  uint32_t now = millis();
  TinyGPSPlus& gps = gpsrx::parser();
  Serial.printf("GPS comms: %s, lock: %s, fix mode: %c, quality: %d\n",
                gpsrx::commsOk(now) ? "OK" : "none", gpsrx::hasLock(now) ? "yes" : "no",
                (char)gps.location.Mode(), (int)gps.location.Quality());
  Serial.printf("Satellites tracked %u, visible %u, HDOP %.1f\n", gps.satellitesStats.nrSatsTracked(),
                gps.satellitesStats.nrSatsVisible(), gpsrx::hdop());
  if (gps.location.isValid())
    Serial.printf("Position %.6f, %.6f (age %lu ms)\n", gps.location.lat(), gps.location.lng(),
                  (unsigned long)gps.location.age());
  if (clk::isSet()) {
    char iso[24], date[16], t[12], zone[8];
    clk::formatIsoUtc(clk::now(), iso, sizeof(iso));
    clk::formatLocal(clk::now(), date, sizeof(date), t, sizeof(t), zone, sizeof(zone));
    Serial.printf("Clock %s (local %s %s %s)\n", iso, date, t, zone);
  } else {
    Serial.println("Clock not set (no GPS time yet)");
  }
  Serial.printf("Card %s, last write %s, %lu row(s) buffered, %lu dropped\n",
                storage::mounted() ? "mounted" : "NOT mounted", tracklog::lastWriteOk() ? "OK" : "FAILED",
                (unsigned long)tracklog::buffered(), (unsigned long)tracklog::droppedRows());
  const DayStats& st = tracklog::stats();
  if (st.known)
    Serial.printf("Today %s: %lu points, %.0f m, Jase %lu, Matt %lu\n", st.date, (unsigned long)st.points,
                  st.distanceM, (unsigned long)st.jase, (unsigned long)st.matt);
  const trip::Meter& tm = trip::meter();
  char since[24] = "the start";
  if (tm.resetUtc) clk::formatIsoUtc(tm.resetUtc, since, sizeof(since));
  Serial.printf("Trip since %s: Jase %lu, Matt %lu, %.0f m, %lu min on the water%s\n", since,
                (unsigned long)tm.jase, (unsigned long)tm.matt, tm.distanceM, (unsigned long)(tm.waterS / 60),
                tm.complete ? "" : " (incomplete: card not read)");
  Serial.printf("Uptime %lu s, free heap %lu bytes\n", (unsigned long)(now / 1000),
                (unsigned long)ESP.getFreeHeap());
}

static void cmdLs(const char* dir) {
  if (!needCard()) return;
  char path[48];
  storage::absPath(dir ? dir : "/", path, sizeof(path));
  Serial.printf("%s:\n", path);
  int n = storage::listFiles(path, false, [](const char* name, size_t size) {
    Serial.printf("  %-24s %10lu\n", name, (unsigned long)size);
  });
  if (n < 0) Serial.println("  (can't open)");
  else Serial.printf("%d file(s)\n", n);
}

static File openForRead(const char* name) {
  char path[64];
  storage::absPath(name, path, sizeof(path));
  File f = SD.open(path, FILE_READ);
  if (!f || f.isDirectory()) {
    if (f) f.close();
    Serial.printf("Can't open %s\n", path);
    return File();
  }
  return f;
}

static void cmdCat(const char* name) {
  if (!needCard()) return;
  File f = openForRead(name);
  if (!f) return;
  uint8_t buf[256];
  size_t n;
  while ((n = f.read(buf, sizeof(buf))) > 0) Serial.write(buf, n);
  f.close();
  Serial.println();
}

static void cmdTail(const char* name, int lines) {
  if (!needCard()) return;
  if (lines <= 0) lines = 10;
  File f = openForRead(name);
  if (!f) return;
  // Walk back from the end counting newlines, a block at a time.
  size_t size = f.size();
  size_t pos = size;
  int found = 0;
  uint8_t buf[256];
  size_t start = 0;
  bool done = false;
  // Ignore a final newline so "last n lines" means n complete lines.
  if (size > 0) {
    f.seek(size - 1);
    if (f.read() == '\n') pos = size - 1;
  }
  while (pos > 0 && !done) {
    size_t chunk = pos < sizeof(buf) ? pos : sizeof(buf);
    pos -= chunk;
    f.seek(pos);
    f.read(buf, chunk);
    for (size_t i = chunk; i-- > 0;) {
      if (buf[i] == '\n' && ++found == lines) {
        start = pos + i + 1;
        done = true;
        break;
      }
    }
  }
  f.seek(start);
  size_t n;
  while ((n = f.read(buf, sizeof(buf))) > 0) Serial.write(buf, n);
  f.close();
}

static void cmdRm(const char* name) {
  if (!needCard()) return;
  if (strcmp(name, "*") == 0) {
    Serial.println("Delete every file in / except readme.txt and trip.txt? Type 'yes' to confirm:");
    s_awaitConfirmRmAll = true;
    return;
  }
  char path[64];
  storage::absPath(name, path, sizeof(path));
  Serial.printf("Removing %s: %s\n", path, SD.remove(path) ? "done" : "FAILED");
}

static void rmAll() {
  if (!needCard()) return;
  tracklog::flush();
  // Collect names first; deleting while iterating the folder isn't safe.
  static char names[64][32];
  int count = 0;
  storage::listFiles("/", false, [&](const char* name, size_t) {
    // trip.txt holds the trip meter's reset time; it's a setting, not a log.
    if (count < 64 && strcasecmp(name, "readme.txt") != 0 && strcasecmp(name, "trip.txt") != 0)
      snprintf(names[count++], 32, "%s", name);
  });
  for (int i = 0; i < count; i++) {
    char path[40];
    snprintf(path, sizeof(path), "/%.31s", names[i]);
    Serial.printf("Removing %s: %s\n", path, SD.remove(path) ? "done" : "FAILED");
  }
  if (count == 64) Serial.println("Stopped at 64 files; run it again for the rest");
}

static void cmdDf() {
  if (!needCard()) return;
  uint64_t total = storage::totalBytes(), used = storage::usedBytes();
  Serial.printf("Card: %llu MB total, %llu MB used, %llu MB free\n", total >> 20, used >> 20,
                (total - used) >> 20);
}

static void runLine(char* line) {
  if (s_awaitConfirmRmAll) {
    s_awaitConfirmRmAll = false;
    if (strcmp(line, "yes") == 0) rmAll();
    else Serial.println("Cancelled");
    return;
  }

  char* tokens[3] = {nullptr, nullptr, nullptr};
  int n = 0;
  for (char* t = strtok(line, " \t"); t && n < 3; t = strtok(nullptr, " \t")) tokens[n++] = t;
  if (n == 0) return;
  const char* cmd = tokens[0];

  if (!strcmp(cmd, "help") || !strcmp(cmd, "?")) printHelp();
  else if (!strcmp(cmd, "status")) cmdStatus();
  else if (!strcmp(cmd, "ls")) cmdLs(tokens[1]);
  else if (!strcmp(cmd, "df")) cmdDf();
  else if (!strcmp(cmd, "cat") && n >= 2) cmdCat(tokens[1]);
  else if (!strcmp(cmd, "tail") && n >= 2) cmdTail(tokens[1], n >= 3 ? atoi(tokens[2]) : 10);
  else if (!strcmp(cmd, "rm") && n >= 2) cmdRm(tokens[1]);
  else if (!strcmp(cmd, "cat") || !strcmp(cmd, "tail") || !strcmp(cmd, "rm"))
    Serial.printf("Usage: %s <file>%s\n", cmd, !strcmp(cmd, "tail") ? " [n]" : "");
  else Serial.printf("Unknown command '%s'. Type 'help'.\n", cmd);
}

void begin() {
  // Serial.begin() on the USB CDC port returns straight away; never wait for a host.
  Serial.begin(CONSOLE_BAUD);
}

void poll(uint32_t) {
  // Bounded per pass so a stream of input can't stall the loop.
  for (int i = 0; i < 128 && Serial.available() > 0; i++) {
    int c = Serial.read();
    if (c < 0) break;
    if (c == '\r' || c == '\n') {
      if (s_overflow) {
        Serial.printf("Line too long (max %d characters), ignored\n", CONSOLE_LINE_MAX);
      } else if (s_len > 0) {
        s_line[s_len] = 0;
        Serial.printf("> %s\n", s_line);
        runLine(s_line);
      }
      s_len = 0;
      s_overflow = false;
    } else if (s_len < CONSOLE_LINE_MAX) {
      s_line[s_len++] = (char)c;
    } else {
      s_overflow = true;
    }
  }
}

}  // namespace console
