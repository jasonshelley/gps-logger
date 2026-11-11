#include "log_reader.h"

#include <SD.h>

#include "config.h"

// Splits a CSV line in place. Returns the number of fields.
static int splitCsv(char* line, char** fields, int maxFields) {
  int n = 0;
  fields[n++] = line;
  for (char* p = line; *p && n < maxFields; p++) {
    if (*p == ',') {
      *p = 0;
      fields[n++] = p + 1;
    }
  }
  return n;
}

bool forEachLogRow(const char* path, const std::function<void(char** fields)>& fn) {
  File f = SD.open(path, FILE_READ);
  if (!f) return false;
  char line[LOG_ROW_MAX];
  size_t len = 0;
  bool overlong = false;
  uint8_t buf[512];
  size_t n;
  while ((n = f.read(buf, sizeof(buf))) > 0) {
    for (size_t i = 0; i < n; i++) {
      char c = (char)buf[i];
      if (c == '\n') {
        line[len] = 0;
        if (len && line[len - 1] == '\r') line[len - 1] = 0;
        if (!overlong) {
          char* fields[LOG_COLS];
          // The header's first field is "type"; data rows are "track" or "catch".
          if (splitCsv(line, fields, LOG_COLS) == LOG_COLS && strcmp(fields[COL_TYPE], "type") != 0)
            fn(fields);
        }
        len = 0;
        overlong = false;
      } else if (len < sizeof(line) - 1) {
        line[len++] = c;
      } else {
        overlong = true;
      }
    }
  }
  f.close();
  return true;
}
