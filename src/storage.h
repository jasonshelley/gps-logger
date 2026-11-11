#pragma once
// SD card on the shared SPI bus. Only use it from the main loop task.

#include <Arduino.h>
#include <FS.h>
#include <functional>

#define UPLOADED_DIR "/uploaded"

namespace storage {

// Mounts the card and prints /readme.txt if there is one. Never blocks for long.
bool begin();
bool mounted();
// Retries the mount at most every few seconds while it's down.
bool ensureMounted(uint32_t nowMs);
// Call after a failed read or write: unmounts so the next ensureMounted() retries.
void markFailed();

// True for root-level log files: gps*.csv.
bool isLogFileName(const char* name);

// Calls fn(name, size) for each file in 'dir' (no subfolders). Names have no path.
// If logOnly, only log files are listed. Returns the number listed, or -1 on error.
int listFiles(const char* dir, bool logOnly, const std::function<void(const char*, size_t)>& fn);

// Moves /<name> to /uploaded/<name>. If /uploaded/<name> already exists (the
// same day was transferred earlier), the new file's rows are appended to it
// without the header line, and /<name> is removed.
bool moveToUploaded(const char* name);

// Builds an absolute path: "x" -> "/x", "/x" -> "/x".
void absPath(const char* in, char* out, size_t len);

uint64_t totalBytes();
uint64_t usedBytes();

}  // namespace storage
