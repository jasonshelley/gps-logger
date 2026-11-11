#pragma once
// Reads log CSV files row by row (used to rebuild today's numbers and the trip meter).

#include <functional>

// Column indexes in the log CSV (see track_logger.h for the header).
enum LogCol {
  COL_TYPE = 0,
  COL_TIME = 1,
  COL_LAT = 2,
  COL_LON = 3,
  COL_COMMENT = 13,
  LOG_COLS = 14,
};

// Calls fn(fields) for every data row with all LOG_COLS columns. The header
// row is skipped and overlong lines are ignored. Fields are only valid during
// the call. Returns false if the file couldn't be opened.
bool forEachLogRow(const char* path, const std::function<void(char** fields)>& fn);
