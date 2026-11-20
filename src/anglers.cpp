#include "anglers.h"

#include <Arduino.h>
#include <SD.h>

#include "clock.h"
#include "storage.h"

namespace anglers {

static const uint8_t kButtonPins[] = ANGLER_BUTTON_PINS;

struct ColourInfo {
  const char* name;
  uint32_t rgb;
};
// LVGL's palette "main" shades. No red: red means an error on the screen.
static const ColourInfo kColours[kColourCount] = {
    {"blue", 0x2196F3}, {"orange", 0xFF5722}, {"green", 0x4CAF50},
    {"purple", 0x9C27B0}, {"teal", 0x009688}, {"pink", 0xE91E63},
};

static Angler s_list[MAX_ANGLERS];
static int s_count = 0;
static bool s_fromCard = false;  // false: defaults, because the card couldn't be read

static void setDefaults() {
  s_count = 2;
  snprintf(s_list[0].name, sizeof(s_list[0].name), "Jase");
  s_list[0].colour = Blue;
  snprintf(s_list[1].name, sizeof(s_list[1].name), "Matt");
  s_list[1].colour = Orange;
}

const char* colourName(uint8_t c) { return c < kColourCount ? kColours[c].name : "blue"; }
uint32_t colourRgb(uint8_t c) { return c < kColourCount ? kColours[c].rgb : kColours[0].rgb; }

static int colourByName(const char* s) {
  for (int i = 0; i < kColourCount; i++)
    if (strcasecmp(s, kColours[i].name) == 0) return i;
  return -1;
}

bool validName(const char* s, size_t len) {
  if (len == 0 || len > ANGLER_NAME_MAX) return false;
  if (s[0] == ' ' || s[len - 1] == ' ') return false;
  for (size_t i = 0; i < len; i++) {
    char c = s[i];
    bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == ' ' ||
              c == '-' || c == '.' || c == '\'';
    if (!ok) return false;
  }
  return true;
}

static bool check(const Angler* list, int n, char* why, size_t whyLen) {
  if (n < 1 || n > MAX_ANGLERS) {
    snprintf(why, whyLen, "Need 1 to %d anglers", MAX_ANGLERS);
    return false;
  }
  for (int i = 0; i < n; i++) {
    if (!validName(list[i].name, strlen(list[i].name))) {
      snprintf(why, whyLen, "Bad name for angler %d", i + 1);
      return false;
    }
    if (list[i].colour >= kColourCount) {
      snprintf(why, whyLen, "Bad colour for angler %d", i + 1);
      return false;
    }
    for (int j = 0; j < i; j++) {
      if (strcasecmp(list[i].name, list[j].name) == 0) {
        snprintf(why, whyLen, "Anglers %d and %d have the same name", j + 1, i + 1);
        return false;
      }
    }
  }
  return true;
}

// Reads the file into 'out'. False if it's missing or has no valid anglers.
static bool readFile(const char* path, Angler* out, int& n) {
  File f = SD.open(path, FILE_READ);
  if (!f) return false;
  n = 0;
  char line[64];
  size_t len = 0;
  bool bad = false;
  auto endLine = [&]() {
    line[len] = 0;
    while (len && (line[len - 1] == '\r' || line[len - 1] == ' ')) line[--len] = 0;
    len = 0;
    if (!line[0] || line[0] == '#') return;
    char* comma = strchr(line, ',');
    if (!comma || n >= MAX_ANGLERS) {
      bad = true;
      return;
    }
    *comma = 0;
    const char* colour = comma + 1;
    while (*colour == ' ') colour++;
    int c = colourByName(colour);
    size_t nameLen = strlen(line);
    if (c < 0 || !validName(line, nameLen)) {
      bad = true;
      return;
    }
    snprintf(out[n].name, sizeof(out[n].name), "%s", line);
    out[n].colour = (uint8_t)c;
    n++;
  };
  int ch;
  while ((ch = f.read()) >= 0) {
    if (ch == '\n') endLine();
    else if (len < sizeof(line) - 1) line[len++] = (char)ch;
  }
  if (len) endLine();
  f.close();
  char why[48];
  if (bad || !check(out, n, why, sizeof(why))) {
    Serial.printf("[anglers] %s isn't valid; using the defaults\n", path);
    return false;
  }
  return true;
}

static void load() {
  Angler tmp[MAX_ANGLERS];
  int n = 0;
  if (readFile(ANGLERS_FILE, tmp, n) || readFile(ANGLERS_TMP_FILE, tmp, n)) {
    for (int i = 0; i < n; i++) s_list[i] = tmp[i];
    s_count = n;
  } else {
    setDefaults();
  }
  s_fromCard = true;
  Serial.printf("[anglers] %d:", s_count);
  for (int i = 0; i < s_count; i++) Serial.printf(" %s (%s)", s_list[i].name, colourName(s_list[i].colour));
  Serial.println();
}

void begin() {
  setDefaults();
  if (storage::mounted()) load();
}

bool reloadIfNeeded() {
  if (s_fromCard || !storage::mounted()) return false;
  load();
  return true;
}

int count() { return s_count; }
const Angler& get(int i) { return s_list[i < 0 ? 0 : i >= s_count ? s_count - 1 : i]; }

int find(const char* name) {
  for (int i = 0; i < s_count; i++)
    if (strcasecmp(name, s_list[i].name) == 0) return i;
  return -1;
}

int buttons() { return (int)(sizeof(kButtonPins) / sizeof(kButtonPins[0])); }

// Writes anglers.tmp, then swaps it in (FAT rename can't replace a file).
static bool save(const Angler* list, int n) {
  if (!storage::ensureMounted(millis())) return false;
  File f = SD.open(ANGLERS_TMP_FILE, FILE_WRITE);
  if (!f) return false;
  bool ok = f.print("# Anglers, in button order: name,colour. Set by the phone app.\n") > 0;
  for (int i = 0; i < n && ok; i++) ok = f.printf("%s,%s\n", list[i].name, colourName(list[i].colour)) > 0;
  f.close();
  if (!ok) return false;
  if (SD.exists(ANGLERS_FILE) && !SD.remove(ANGLERS_FILE)) return false;
  return SD.rename(ANGLERS_TMP_FILE, ANGLERS_FILE);
}

SetResult set(const Angler* list, int n, char* why, size_t whyLen) {
  if (!check(list, n, why, whyLen)) return SetResult::Invalid;
  if (!save(list, n)) {
    storage::markFailed();
    snprintf(why, whyLen, "Couldn't save the anglers");
    return SetResult::SaveFailed;
  }
  for (int i = 0; i < n; i++) s_list[i] = list[i];
  s_count = n;
  s_fromCard = true;
  return SetResult::Applied;
}

// ---- Log comments ----

static bool copyName(const char* s, size_t len, char* name, size_t nameLen) {
  if (len == 0 || len >= nameLen) return false;
  memcpy(name, s, len);
  name[len] = 0;
  return true;
}

bool parseCatch(const char* comment, char* name, size_t nameLen) {
  size_t len = strlen(comment);
  if (len < 7 || strcasecmp(comment + len - 6, " catch") != 0) return false;
  return copyName(comment, len - 6, name, nameLen);
}

bool parseUndo(const char* comment, char* name, size_t nameLen, time_t& catchUtc) {
  catchUtc = 0;
  size_t len = strlen(comment);
  if (len >= 6 && strcasecmp(comment + len - 5, " undo") == 0) return copyName(comment, len - 5, name, nameLen);
  // "<name> undo <time>": the time is the last word.
  const char* sp = strrchr(comment, ' ');
  if (!sp || sp - comment < 6 || strncasecmp(sp - 5, " undo", 5) != 0) return false;
  catchUtc = clk::parseIsoUtc(sp + 1);
  if (catchUtc == 0) return false;
  return copyName(comment, (size_t)(sp - 5 - comment), name, nameLen);
}

}  // namespace anglers
