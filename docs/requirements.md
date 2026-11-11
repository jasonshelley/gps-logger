# ESP32 GPS Logger: requirements derived from the code

Status: draft 3, 2026-11-11. Derived from the code, then refined with Jason, then updated after the rewrite (see **Build notes** at the end). Where they disagree, the Decisions section overrides the requirements derived from the code, and the Build notes override both.

## What the device is

A handheld GPS logger built on a Waveshare ESP32-C6 board with a 1.47" LCD. It records a GPS track to an SD card, and two buttons let two people ("Jase" and "Matt") mark the spot where they caught something. A toggle switch moves it between logging and uploading, but uploading was never built on this board.

## Where these requirements came from

| Source | Path | Last changed | State |
|---|---|---|---|
| Copy 1 | `C:\Users\jason\Downloads\ESP32-C6-LCD-1.47-Demo\Arduino\examples\LVGL_Arduino\` | 14 Jan 2026 | Halfway through turning the display into a class. Most of the screen updates are commented out, and so is the LVGL tick timer. |
| Copy 2 | `...\examples\LVGL_Arduino - Copy\LVGL_Arduino_og\` | 16 Jan 2026 | Newest. Display works, plus HDOP filtering, a log file per day, and a serial command console. |
| Older snapshots | `C:\src\esp32\ESP32-C6-LCD-1.47-Demo\Arduino\examples\` | 2 to 14 Jan 2026 | Earlier stages of copies 1 and 2. Nothing in them is missing from the copies above. |
| Uno version | `C:\Users\jason\Documents\Arduino\GpsLogger\` | 2 Jan 2026 | Earlier Arduino Uno R4 WiFi build. I used it only to see what "upload" was meant to do. |

In the requirements below, **[1]** means only copy 1 does it, **[2]** means only copy 2, and **[both]** means both copies do it. Where the two copies disagree, I've used copy 2's behaviour and noted the difference.

## Hardware

| Item | Detail |
|---|---|
| Board | Waveshare ESP32-C6-LCD-1.47 |
| Display | ST7789, 172 × 320, portrait, SPI. MOSI 6, SCLK 7, CS 14, DC 15, RST 21, backlight 22 |
| SD card | On the same SPI bus. CS is GPIO 4 and MISO is GPIO 5 |
| GPS receiver | UART1 at 9600 baud, 8N1. ESP RX is GPIO 19, ESP TX is GPIO 18. Sends NMEA |
| "Jase" button | GPIO 5, active low, internal pull-up |
| "Matt" button | GPIO 4, active low, internal pull-up |
| Mode switch | GPIO 3, internal pull-up. LOW means Upload, HIGH means Logging |
| Libraries | LVGL 8.3.10, SdFat, TinyGPSPlusPlus 0.0.4 (a TinyGPSPlus fork that adds satellite counts, fix quality and fix mode) |

**The buttons share pins with the SD card.** The Matt button and SD CS are both GPIO 4, and the Jase button and SD MISO are both GPIO 5. See D1.

## Functional requirements

### Operating modes

```mermaid
stateDiagram-v2
    [*] --> Upload : boot (mode starts as Upload until the switch settles)
    Upload --> Logging : switch HIGH for over 250 ms
    Logging --> Upload : switch LOW for over 250 ms
    Logging : Logging\nWi-Fi off, read GPS, log fixes, logger screen
    Upload : Upload\nWi-Fi on, upload screen, no logging
```

- **FR-1 [both]** A two-position switch picks the mode: Logging or Upload.
- **FR-2 [both]** The switch is debounced. A new position only counts after it has held for more than 250 ms.
- **FR-3 [both]** In Logging mode, Wi-Fi is off and the logger screen is shown.
- **FR-4 [both]** In Upload mode, the device joins a fixed Wi-Fi network and shows the upload screen. Its border is green when connected and red when not.
- **FR-5 [both]** In Upload mode, GPS data isn't read or logged.
- **FR-6 (not built)** In Upload mode, upload the log files. The ESP32 code only has a `// Do upload stuff` placeholder. The Uno version POSTed `gps.log` to an Azure Function (`/api/Upload`) as multipart form data, and recorded uploaded file names in `upload.txt`.

### Reading GPS and accepting a fix

- **FR-7 [both]** Read NMEA from the GPS UART all the time while in Logging mode.
- **FR-8 [both]** A fix is accepted for logging when:
  - the location is valid,
  - its latitude or longitude differs from the last accepted fix (a stationary repeat isn't logged), and
  - **[2]** HDOP is 5 or less. If no HDOP has been received, it's treated as 100. Copy 1 has no HDOP check.
- **FR-9 [2]** "GPS comms OK" means at least one byte arrived from the GPS in the last 1000 ms.
- **FR-10 [2]** "Has lock" means a fix was accepted in the last 5000 ms and the current HDOP is 5 or less.

### Logging to SD

- **FR-11 [both]** Each accepted fix becomes one comma-separated record with these fields:

  | # | Field | Format |
  |---|---|---|
  | 0 | Satellites tracked | integer |
  | 1 | Satellites visible | integer |
  | 2 | HDOP | 1 decimal place |
  | 3 | Latitude | 6 decimal places |
  | 4 | Longitude | 6 decimal places |
  | 5 | Age of the location fix | ms |
  | 6 | Date (UTC) | `MM/DD/YYYY` |
  | 7 | Time (UTC) | `HH:MM:SS`. Copy 1 adds `.cc` (centiseconds) |
  | 8 | Age of the date | ms |
  | 9 | Altitude | metres, 2 decimal places |
  | 10 | Course | degrees, 2 decimal places |
  | 11 | Speed | km/h, 2 decimal places |
  | 12 | Fix quality | integer (GGA quality) |
  | 13 | Fix mode | single character (RMC mode, such as A, D or N) |
  | 14 | Comment | text, such as `Jase catch` |

  Every field, including the last one, ends with a comma. The file has no header row.
- **FR-12 [both]** Records are held in RAM and written to the card 30 at a time.
- **FR-13** Log file name:
  - **[2]** `gpsYYYYMMDD.log`, using the UTC date of the 30th record in the batch. Records are appended.
  - **[1]** `gps.log`, always the same file.
- **FR-14 [both]** Files get their created and modified timestamps from GPS time.
- **FR-15 [both]** At boot, if `readme.txt` is on the card, its contents are printed to the serial port.

### Marking a catch

- **FR-16 [both]** There are two buttons, Jase and Matt. They're active low, debounced for 50 ms, and a press counts once until the button is released.
- **FR-17 [both]** A press is saved until the next accepted fix. That fix's comment is then set to `Jase catch` or `Matt catch`. If both were pressed, Matt wins.
- **FR-18 [both, probably a bug]** The comment is never cleared. Every record after the first press carries the same comment. See D2.

### Logger screen (172 × 320)

From top to bottom:

- **FR-19** Two arc gauges, each 75 px and spanning 270°:
  - **[2]** Left arc: satellites tracked, from 0 to 16. Right arc: HDOP, labelled "HDOP".
  - **[1]** Left arc: tracked. Right arc: visible.
  - Satellite arc colour: green when there's a lock, orange when more than 1 satellite, red otherwise.
  - **[2]** HDOP arc: the value is `1000 − HDOP×10`, so a fuller arc means better accuracy. Colour: green when HDOP is 5 or less, orange when under 50, red otherwise.
- **FR-20 [both]** Course in degrees and as a compass point (such as NE), in a 24 pt font. **[2]** It shows `--` when the course isn't valid or HDOP is over 5.
- **FR-21 [both]** Speed in km/h to 1 decimal place, in 24 pt. It follows the same `--` rule.
- **FR-22 [both]** Date as `DD/MM/YYYY` and time as `HH:MM:SS (UTC)`, in 20 pt, or `--` when they're not valid.
  - The display shows the date day-first, but the log stores it month-first. See D5.
- **FR-23 [both]** Uptime since boot, as `N days, HH : MM : SS`, in 12 pt.
- **FR-24 [both]** A bar showing how many records are waiting to be written, from 0 to 30. It shades from green to red.
- **FR-25 [2]** The screen border is green when GPS comms are OK and red when they're not. Copy 1 also briefly turns it yellow when a fix arrives.
- **FR-26 [2]** Satellites, course and speed refresh at most once a second. Date, time and uptime update on every pass of the main loop.
- **Styling:** grey separator lines, a black rounded container with a 3 px border, and white text.

### Serial console [2]

- **FR-27** USB serial at 115200 baud, taking one command per line:

  | Command | What it does |
  |---|---|
  | `status` | Prints the GPS fix mode |
  | `ls` | Lists files in the card's root folder with their sizes |
  | `cat <file>` | Prints a file |
  | `rm <file>` | Deletes a file and reports whether it worked |
  | `rm *` | Deletes every file in the root folder except `readme.txt` |

- **FR-28 [both]** Debug messages are printed to serial, such as button presses, screen changes, file writes and Wi-Fi attempts.

### Startup [2]

- **FR-29** Print the flash size, then start the LCD, LVGL, SD card and screens. Then start USB serial and wait for it to connect, then start the GPS UART.

## Defects and gaps found in the code

These aren't requirements. Each one needs a decision before the rewrite.

| # | What I found | Effect |
|---|---|---|
| D1 | The buttons share GPIO 4 and 5 with SD CS and MISO. | A Matt press pulls the SD chip select low. SD reads may break or read as button presses. What's actually wired? |
| D2 | The catch comment is never reset (FR-18). | After the first press, every record says "X catch". |
| D3 | Records only reach the card in batches of 30. Switching mode or losing power doesn't trigger a write. | Up to 29 fixes are lost at power-off, and the catch you just marked may be among them. |
| D4 | The file is named by the date of the 30th record, in UTC. | A batch that crosses UTC midnight lands in the next day's file. In Australia, UTC midnight is mid-morning. |
| D5 | The log stores dates as MM/DD/YYYY but the screen shows DD/MM/YYYY. The log has no header row and ends each line with a trailing comma. | The CSV is awkward to import. |
| D6 | Copy 2 waits in `while (!Serial)` at boot. | On the ESP32-C6's USB serial, the logger probably won't start unless a computer is connected. |
| D7 | Wi-Fi connect calls `WiFi.begin()` and checks the status straight away, then does it all again on every loop pass. | The first check always fails, and calling `begin` again may keep restarting the connection. |
| D8 | Upload isn't built (FR-6). | Upload mode only connects to Wi-Fi. |
| D9 | The serial command reader keeps reading until it gets `\n`, with no length limit, and counts "no data" as a character. | A long line or a slow sender overruns the 64-byte buffer. |
| D10 | Date and time show `--` unless the time changed since the last read, and they're redrawn about every 5 ms. | The date and time probably flicker to `--`. |
| D11 | Wi-Fi SSID and password are hard-coded in the sketch. | Secrets end up in the source. The Uno version also hard-codes Azure keys. |
| D12 | Copy 1 has the LVGL tick timer commented out. | Animations and timers in copy 1 probably don't advance. That may be why copy 2 was restarted from the original example. |
| D13 | At boot, the mode starts as Upload until the switch has been read for 250 ms. | Every boot briefly tries to connect to Wi-Fi. |
| D14 | Stationary repeats are dropped (FR-8). | Time spent stopped isn't in the track, and a catch made while stopped is only marked when the boat next moves. |

## Decisions

| # | Question | Decision |
|---|---|---|
| 1 | Use | Fishing. Two buttons, fixed to Jase and Matt in the code. |
| 2 | Catch marking | A press writes a catch record straight away at the current position, even when stationary, and writes it to the card at once. Only that record carries the comment. The screen briefly shows "Jase catch!" or "Matt catch!", and keeps a catch count per person for the day. Assumed: the count is rebuilt from today's log at boot, so it survives a restart. |
| 3 | Upload | Upload goes over Bluetooth LE to an Android phone. The receiver is a web page I'll write, using Web Bluetooth in Chrome on Android. It saves files to the phone's Downloads, and won't work on iPhone. A file that transfers successfully moves to `/uploaded` on the card. Wi-Fi is removed completely, credentials included. The mode switch now chooses between Logging and Transfer (Bluetooth on). Still to settle: where the page is hosted, since Web Bluetooth needs HTTPS (for example GitHub Pages). Note that Bluetooth LE moves roughly 5 to 20 KB/s, so log size matters (Q4, Q6). |
| 4 | Log format | The device writes a tidied CSV: a header row, ISO 8601 UTC time (`2026-11-11T08:15:02Z`), no trailing comma, and the two age fields dropped. The phone page turns it into GPX, with track points plus a waypoint for each catch. Assumed: the page can also save the raw CSV. |
| 5 | Data safety | Buffered track points are written to the card every 10 s. They're also written straight away on a catch, on a mode switch, and on low battery if that can be detected. At most about 10 s of track is lost at power-off. |
| 6 | Log rate | A point is logged when 5 s have passed or the position has moved 10 m, whichever comes first. While stationary, a point is logged every 60 s, which replaces "drop stationary repeats" and fixes D14. That's about 0.5 MB per day. |
| 7 | Accuracy filter | Track points are logged only when HDOP is 5 or less, a fixed value as in copy 2. Speed and course show `--` above that. A catch is always recorded: if the current fix is poor, it uses the last good fix and records how old that fix is. |
| 8 | Time zone | The screen and file names use Sydney/Melbourne local time, switching between AEST and AEDT automatically. Times inside the log stay in UTC (ISO, ending `Z`). Each record goes in the file for its own local date, which fixes D4. |
| 9 | Wiring and power | Not built yet, so I'm choosing the pins. Proposed: Jase button GPIO 1, Matt button GPIO 2, mode switch GPIO 3, all active low to GND with internal pull-ups. GPS stays on RX 19 / TX 18. To check against the Waveshare pinout before wiring. Powered from a USB power bank, so there's no battery-level reading or low-battery write (Q5). Startup must not wait for a computer on USB (D6). |
| 10 | Screens | **Logger screen:** keep the tracked-satellites arc, the HDOP arc, course, speed, local date and time, and the comms border. Remove uptime and the buffer bar. Add catch counts for Jase and Matt, the catch banner (Q2), today's distance travelled (rebuilt from today's log at boot), and a logging status line: OK, SD error or no fix, plus points logged today. **Transfer screen:** shows the Bluetooth state (waiting or connected), the file being sent, a progress bar, and how many files are left. |
| 11 | Serial console | Keep `status`, `ls`, `cat`, `rm <file>` and `rm *`, with input limited to the buffer size (fixes D9). Add `help`, `df` (card space), `tail <file> [n]` and `ls /uploaded`. `rm *` asks for confirmation and still keeps `readme.txt`. |
| 12 | Build setup | A PlatformIO project on LVGL 8, keeping the working ST7789 driver, with pinned library versions and its own `lv_conf.h`. Note: the official PlatformIO ESP32 platform doesn't support the ESP32-C6 with Arduino core 3.x, so this will probably need the community `pioarduino` platform. The project lives in `C:\src\mine\gps-logger` as a local git repo with no remote. |

### Settled during the build (were "Still to settle")

- **Phone page hosting:** GitHub Pages. `web/index.html` is a single static file. Push it to a GitHub repository and turn on Pages, as the README describes. That gives HTTPS, which Web Bluetooth needs. Nothing has been published yet; that's Jason's call. For testing from a PC, `http://localhost` also counts as secure.
- **Pins (Q9):** confirmed against Waveshare's schematic (`ESP32-C6-LCD-1.47_schemetics.pdf`). Jase GPIO 1, Matt GPIO 2 and the mode switch GPIO 3 are all on header U2 (pins 14, 15 and 16), with nothing else connected. None of them is a strapping pin (the ESP32-C6's are 4, 5, 8, 9 and 15). GPIO 0/1 would take a 32 kHz crystal, but the board doesn't fit one. GPS stays on RX 19 / TX 18 (U2 pins 3 and 2). The pins are in `include/config.h` and in the README's wiring table. This resolves D1.

## Open questions for refinement

1. ~~**Use:**~~ Decided, see Decisions. Is this for fishing, logging the track and where each person caught a fish? Is it always two named people, or should names and button count be settings?
2. ~~**Catch marking:**~~ Decided, see Decisions. Should a press log a separate catch record straight away, even if the position hasn't changed? Should it give feedback such as a screen flash or a counter? Should the screen show a catch count per person?
3. ~~**Upload:**~~ Decided, see Decisions. Is upload still wanted? Where would files go: the Azure Function, a phone over Wi-Fi or Bluetooth, or just taking the SD card out? What should happen to a file after it uploads (delete, move, or record it as uploaded)?
4. ~~**Log format:**~~ Decided, see Decisions. Keep the CSV fields above, or change them? Options include a header row, ISO dates, and dropping the age fields. Or should it write GPX directly? The Uno folder has a `gpx/log.gpx`.
5. ~~**Data safety:**~~ Decided, see Decisions. How many fixes can you afford to lose at power-off? One option is to write every N seconds, or straight away when a catch is marked, and on every mode switch.
6. ~~**Log rate:**~~ Decided, see Decisions. Log every accepted fix (about 1 Hz), or apply a minimum time or distance between points?
7. ~~**Accuracy filter:**~~ Decided, see Decisions. Keep the HDOP ≤ 5 cut-off? Should it be a setting?
8. ~~**Time zone:**~~ Decided, see Decisions. Show local time (AEST/AEDT) on the screen, and name files by local date?
9. ~~**Wiring:**~~ Decided, see Decisions. Which GPIOs are the buttons and switch actually on (D1)? What's the GPS module? Is it on battery, and is a battery-level display wanted?
10. ~~**Screen:**~~ Decided, see Decisions. Keep copy 2's layout (tracked arc plus HDOP arc), or show visible satellites as copy 1 did? Is anything missing, such as lat/lon, distance travelled or the current file name?
11. ~~**Serial console:**~~ Decided, see Decisions. Keep it? Are any more commands wanted, such as `df`, `tail`, or a way to set Wi-Fi details?
12. ~~**Rewrite scope:**~~ Decided, see Decisions. Stay on Arduino IDE and LVGL 8, or move to PlatformIO and/or LVGL 9? Where should the new project live, and should it be a git repo?

## Build notes

Where the rewrite had to settle something the decisions left open, or found that the code or tools didn't match an assumption. These override the requirements above.

| # | Topic | What was built |
|---|---|---|
| B1 | Pins | As Q9: Jase GPIO 1, Matt GPIO 2, mode switch GPIO 3 (LOW = Transfer). The hardware table above still shows the old sketch's clashing pins, kept for the record. |
| B2 | Boot mode | The switch is read at boot (majority of 5 reads over about 10 ms), so the device starts in the mode the switch is in. Fixes D13. After boot, a change still needs 250 ms of stable input. |
| B3 | "Stationary" (Q6) | Revised 2026-11-11, because GPS jitter on a desk logged a point every 5 s and counted kilometres. Moving now means the movement rule in `docs/metrics.md` confirmed a move in the last 2 min: the position stayed at least max(25 m, 30 m × HDOP) from the last counted position for 30 s. Moving: log every 5 s. Otherwise: log every 60 s. A fix that completes a move is always logged, and so is the first good fix after boot. GPS speed is no longer used (indoors it read 2–14 km/h while still). The earlier rule was "under 2 km/h and less than 10 m from the last logged point". |
| B4 | "Has lock" | A fix that passed the filter (valid, HDOP ≤ 5, under 2 s old) in the last 5 s, and current HDOP ≤ 5. It no longer depends on a point being logged, since the log rule now skips most fixes. |
| B5 | CSV columns (Q4, Q7) | `type,time_utc,lat,lon,alt_m,speed_kmh,course_deg,hdop,sats_tracked,sats_visible,fix_quality,fix_mode,fix_age_s,comment`. `type` (`track`/`catch`) was added so the phone and the boot rebuild don't have to parse the comment. The two old age fields are gone as Q4 decided. `fix_age_s` is new: it's the fix age Q7 asks for, filled only on catch rows. A catch row's time is the time of the press. |
| B6 | Catch before the GPS knows the date | The file name needs the local date. A catch pressed before the clock has ever been set goes to `/gpsnodate.csv` (empty time, and empty position unless a fix exists). It counts towards the first day the clock then shows. The transfer lists it like any log file. |
| B7 | Rebuilding today's numbers (Q2, Q10) | This can't happen literally at boot, because the date comes from the GPS. It happens as soon as the clock is first set from the GPS, and again at local midnight. It reads `/uploaded/gpsYYYYMMDD.csv` (if part of today was already transferred) and then `/gpsYYYYMMDD.csv`. The last track point also seeds the "last good fix", so a catch before the first fix after a restart still gets a position, with its age. |
| B8 | Same-day transfer twice | When a confirmed file's name already exists in `/uploaded`, its rows (minus the header) are appended to that file and the original is deleted. Chrome saves the second download as `gpsYYYYMMDD (1).gpx`. See `docs/ble-protocol.md`. |
| B9 | Transfer mode | The GPS is still parsed so the clock stays right, but nothing is logged (FR-5). Catch buttons are ignored. NimBLE starts the first time Transfer mode is entered and then stays loaded, but it only advertises in Transfer mode. Leaving Transfer stops advertising and disconnects the phone. |
| B10 | Both buttons together | Each press writes its own catch record. Copy 2's "Matt wins" rule only existed because of the single shared comment. |
| B11 | Card failures | A failed write keeps the rows in RAM (up to 32, oldest dropped after that, counted in `status`). The card is remounted every 5 s until it's back. The status line shows `SD error`, and the catch banner shows `NOT SAVED` if that catch didn't reach the card. |
| B12 | Time | The system clock is set from GPS UTC (`settimeofday`), and local time uses the POSIX TZ rule `AEST-10AEDT,M10.1.0,M4.1.0/3`. The screen reads the system clock, so the date and time don't flicker (fixes D10). FAT timestamps on the card also come from the system clock, in local time (FR-14). |
| B13 | Startup (FR-29) | Order: USB serial (never waits), LCD, LVGL, inputs, clock, SD, screens, GPS UART. `/readme.txt` is still printed if present (FR-15). |
| B14 | LVGL config | The `lv_conf.h` the old sketch used (`Documents\Arduino\libraries\lv_conf.h`) is actually an **LVGL 9** template, compiled against LVGL 8.3.10, so most of it was ignored. The project has its own LVGL 8.3 `lv_conf.h`. `LV_COLOR_16_SWAP` stays 0, because the ST7789 init sets RAMCTRL (0xB0) to little-endian. The display now redraws only dirty areas, where copy 2 redrew the whole screen on every change. |
| B15 | Build target | pioarduino `55.03.312-1` (Arduino core 3.3.12). The `esp32-c6-devkitm-1` board definition (4 MB flash) is used. Waveshare's schematic shows a C6FH4 (4 MB), but esptool says Jason's board is an ESP32-C6FH8 (8 MB, rev v0.2). The 4 MB layout runs on it and leaves the upper 4 MB unused. Moving to an 8 MB layout would change the partitions, so it's left for Jason to decide. The partition table is `huge_app.csv` (3 MB app, no OTA). The firmware is about 1.07 MB, which would only just fit a default 1.25 MB OTA slot, and nothing uses OTA. NimBLE-Arduino 2.5.2 provides BLE. |
| B16 | Bluetooth security | No pairing. Anyone in range can list and download logs while the switch is on Transfer, and can confirm (move) a file if they send its correct CRC. That's acceptable for a fishing logger, and noted in the protocol doc. |

| B17 | Trip meter (added after the rewrite) | Jason asked for a car-style trip meter that the app controls, so no new button. It counts catches per angler, distance and time on the water from a reset time the app sends over BLE (protocol v2, `METER_RESET`). It's stored in `/trip.txt` and rebuilt from the logs at boot. On the logger screen it replaces today's per-person catch counts and today's distance, which overrides that part of Q10. Today's points stay on the status line. Distance and "time on the water" follow the movement rule in `docs/metrics.md` (revised 2026-11-11). The first version summed every pair of consecutive points at most 15 min apart, and showed 3.2 km and 1 h 05 min for a logger left on a desk. Time on the water is now each segment's first move to its last, so time at anchor counts but a logger sitting still doesn't. Today's distance uses the same rule. The phone app must use it too. See `docs/ble-protocol.md`, `docs/metrics.md` and the README. |

### To check on the hardware

None of this has run on the board yet. On first power-up, check:

1. The screen draws correctly with partial refresh: no offset, tearing or wrong colours. If it's wrong, set `full_refresh = 1` in `src/lvgl_port.cpp`, as copy 2 had it.
2. The SD card mounts at 20 MHz alongside the LCD on the shared bus. If not, lower `SD_SPI_HZ` in `config.h`.
3. Buttons on GPIO 1/2 and the switch on GPIO 3 read correctly, and the device boots straight into the switch's mode.
4. The GPS on RX 19 / TX 18 gives time, fix, HDOP and satellite counts. The clock shows AEDT now (DST is on in November).
5. Track points follow the log rule: one a minute while still (even indoors with a wandering fix), every 5 s while moving. Catches write straight away, and counts and distance come back after a restart once the GPS has the time.
6. The console works with a PC attached, and the logger runs normally from a power bank with nothing on USB.
7. Chrome on Android finds "GPS Logger" by its service filter, the negotiated MTU gives 239-byte chunks, and the transfer speed is reasonable (expect 5–20 KB/s).
8. A confirmed file moves to `/uploaded`, and a second transfer of the same day appends to it.
9. Trip meter: a reset from the app writes `/trip.txt`, zeroes the screen's trip line (or recounts from the reset time), survives a restart, and a repeated reset with the same time changes nothing.
10. Movement rule: after an hour on a desk in Logging mode, the trip distance and time on the water haven't moved. On the water, they go up while motoring and drifting, and time at anchor between moves counts.
