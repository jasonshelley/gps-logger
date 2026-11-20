# ESP32-C6 fishing GPS logger

A handheld GPS logger on a Waveshare ESP32-C6-LCD-1.47. It records the boat's track to an SD card, and a button per angler marks each catch (hold it to undo). Holding BOOT puts it into Transfer mode, where a phone downloads the logs over Bluetooth LE and saves them as GPX.

- Requirements and decisions: [docs/requirements.md](docs/requirements.md)
- Bluetooth protocol: [docs/ble-protocol.md](docs/ble-protocol.md)
- Phone page: [web/index.html](web/index.html)
- Pins and tuning constants: [include/config.h](include/config.h)

## Hardware

| Part | Notes |
|---|---|
| Waveshare ESP32-C6-LCD-1.47 | ESP32-C6 with in-package flash (the schematic says C6FH4, 4 MB; Jason's unit is a C6FH8, 8 MB). 172 × 320 ST7789 LCD, microSD slot, USB-C. The build uses a 4 MB layout, which runs on either |
| GPS receiver | Any NMEA receiver at 9600 baud, 8N1 |
| 2 momentary buttons | Catch buttons for anglers 1 and 2 (Jase and Matt unless the app renames them) |
| 1 two-position switch | Optional: Logging / Transfer. Holding BOOT does the same |
| microSD card | FAT32 |
| USB power bank | Powers it through the USB-C port |

### Wiring

The board has two rows of header pins, one along each long side. Waveshare's schematic (`ESP32-C6-LCD-1.47_schemetics.pdf`) calls the header U2 and numbers it like a chip: pins 1–9 run down one side, and pins 10–18 run back up the other. So pin 1 is opposite pin 18, and pin 9 is opposite pin 10.

The schematic doesn't show which end is nearest the USB-C port, or which face of the board it's drawn from. **Go by the pin labels printed on your board**, not by counting from an end.

Everything except the two GPS data wires goes on the **IO0–IO5 / 5V / GND / 3V3 row**.

| Row A (U2 pins 1–9) | Use | Opposite | Row B (U2 pins 18–10) | Use |
|---|---|---|---|---|
| 1 · BOOT (IO9) | – | ↔ | 18 · IO5 | – (SD MISO) |
| 2 · IO18 | **GPS RX** (ESP TX) | ↔ | 17 · IO4 | – (SD CS) |
| 3 · IO19 | **GPS TX** (ESP RX) | ↔ | 16 · IO3 | **Mode switch** |
| 4 · IO20 | spare | ↔ | 15 · IO2 | **Matt button** |
| 5 · IO23 | spare | ↔ | 14 · IO1 | **Jase button** |
| 6 · USB_N | – | ↔ | 13 · IO0 | spare |
| 7 · USB_P | – | ↔ | 12 · 3V3 | GPS power (if 3.3 V) |
| 8 · RXD | spare | ↔ | 11 · GND | **Ground** |
| 9 · TXD | spare | ↔ | 10 · 5V | GPS power (if 5 V) |

All three inputs are active low: wire each between its GPIO and GND. The internal pull-ups are on, so no resistors are needed.

| Function | GPIO | Row | Label | Connect to |
|---|---|---|---|---|
| Jase button | **1** | B | IO1 | button → GND |
| Matt button | **2** | B | IO2 | button → GND |
| Mode switch | **3** | B | IO3 | switch → GND. Closed = **Transfer**, open = **Logging** |
| Ground | – | B | GND | GPS GND, and the common side of both buttons and the switch |
| GPS power | – | B | 3V3 or 5V | whichever the GPS module needs |
| GPS TX → ESP RX | **19** | A | IO19 | GPS module TX |
| ESP TX → GPS RX | **18** | A | IO18 | GPS module RX |

"Row A" and "Row B" are names used only in this README, not markings on the board.

**Why GPIO 1, 2 and 3:** the schematic shows nothing else on them. They aren't strapping pins (on the ESP32-C6 those are 4, 5, 8, 9 and 15). GPIO 0 and 1 can take a 32 kHz crystal, but this board doesn't fit one, so GPIO 1 is free.

**Don't use these GPIOs** (these are GPIO numbers, not header pin numbers):

- GPIO 4 and 5 (labels IO4, IO5): SD CS and MISO, which are also strapping pins. The old sketch had the buttons here.
- GPIO 6, 7, 14, 15, 21, 22: the LCD. Not on the header.
- GPIO 8: the RGB LED. Not on the header.
- GPIO 9 (label BOOT): the BOOT button, used for the details page and switching modes.
- GPIO 12 and 13 (labels USB_N, USB_P): USB.

IO0, IO20, IO23 and the TXD/RXD pins are spare.

## Building

You need [PlatformIO](https://platformio.org/). Either install the VS Code extension, or install the CLI with `pip install platformio`.

```bash
pio run
```

The first build downloads the pioarduino platform (Arduino core 3.3.12 for the ESP32-C6), the RISC-V toolchain and the libraries. That's about 1 GB.

**On Windows:**

- The ESP32 core has file paths up to 260 characters long. That's too long even under `C:\Users\<you>\.platformio` unless Windows long paths are turned on. Either turn on long paths (an admin setting: `LongPathsEnabled` = 1), or give PlatformIO a short core folder before building. On this machine the build uses `C:\pio`:

  ```powershell
  $env:PLATFORMIO_CORE_DIR = "C:\pio"
  ```

- Run `pio` from PowerShell or cmd, not Git Bash. pioarduino's tool installer refuses to run under MSYS/MinGW, and if it doesn't run, the compiler isn't set up (`riscv32-esp-elf-gcc is not recognized`).

On this PC, [tools/pio.ps1](tools/pio.ps1) does both: it uses PlatformIO from `C:\pio\venv` with the core in `C:\pio`. From the project folder in PowerShell:

```powershell
.\tools\pio.ps1 run
.\tools\pio.ps1 run -t upload --upload-port COM3
```

A clean build uses about 28% of RAM (92 KB) and 1.23 MB of the 3 MB app partition. Each build writes the git commit to `include/fw_version.h` (not in git) for the details page; a `+` after it means the firmware had uncommitted changes.

Pinned versions (see [platformio.ini](platformio.ini)):

| Package | Version |
|---|---|
| pioarduino platform-espressif32 | 55.03.312-1 (Arduino core 3.3.12, ESP-IDF 5.5.5) |
| lvgl/lvgl | 8.3.11 |
| ress997/TinyGPSPlusPlus | 0.0.4 |
| h2zero/NimBLE-Arduino | 2.5.2 |

The official PlatformIO espressif32 platform only has Arduino core 2.x, which doesn't support the ESP32-C6, so the project uses the community [pioarduino](https://github.com/pioarduino/platform-espressif32) platform. The project's own LVGL config is [include/lv_conf.h](include/lv_conf.h).

## Flashing

Plug the board into the PC with USB-C, then:

```bash
pio run -t upload
```

If the upload can't connect, hold **BOOT**, tap **RESET**, release BOOT, and try again. Then tap RESET to run.

To watch the console:

```bash
pio device monitor
```

The logger never waits for a computer. It boots and logs the same with or without USB connected.

## Using it

### Logging mode

The logger reads the GPS and writes a track point:

- every 5 s while moving
- every 60 s otherwise
- only when HDOP is 5 or less

"Moving" means the movement rule in [docs/metrics.md](docs/metrics.md) confirmed a move in the last 2 minutes: the position stayed at least max(25 m, 30 m × HDOP) from where it was for 30 s. The point that completes a move is always logged. GPS speed isn't used, because it reads several km/h when the logger is sitting still indoors. So a logger left on a desk writes one point a minute, however much its position wanders.

Each catch button belongs to an angler: button 1 is the first angler, button 2 the second (see [Anglers](#anglers)).

- **Press** a catch button: a catch record is written as you let go, at the current position, and a banner in the angler's colour shows their new count for 3 s. If the current fix is poor, the catch uses the last good fix and records how old it is. The banner turns red with "NOT SAVED" if the card write failed.
- **Hold** a catch button for 2 s: undoes that angler's most recent catch. The grey banner says "undone" with the new count, or "nothing to undo". Holding again undoes the catch before that, back as far as the last trip reset. The catch row stays in the log; an undo row after it cancels it (see [CSV columns](#csv-columns)).

Buffered track points reach the card every 10 s, and also straight away on a catch or a mode switch. A power cut loses at most about 10 s of track.

### Logger screen

Big numbers in cards, so it reads at a glance and with the backlight dimmed. From the top:

- **Status strip**: a dot and the GPS state on the left (`GPS fix`, `No fix`, `No GPS` or `SD error`), local time (Sydney) on the right.
- **Catches** for each angler since the trip meter was last reset: names in the anglers' colours over big digits, or a 2 × 2 grid for 3 or 4 anglers.
- **Trip**: distance moved, then time on the water (h:mm). A `?` after the distance means the card couldn't be read to rebuild the meter.
- Two half-width cards at the bottom:
  - **Speed** in km/h, with the course below as a compass point and degrees. These show `--` without a good fix.
  - **GPS**: satellites tracked, with or without a fix, and HDOP. HDOP shows `--` until there's a fix; it's green at 2 or better, white up to 5, and orange above 5, where speed and course are hidden and moves aren't counted.
- **The border is the health light**: green while logging, orange with no fix, red when the GPS has gone quiet or the card has failed.

A catch press shows a banner in the angler's colour with their new count for 3 s (red with `NOT SAVED` if the card write failed).

**Backlight:** bright for 30 s after any button press, a mode switch, or while the phone is connected in Transfer mode, then dimmed to save the battery. The levels and the time are in `config.h` (`BACKLIGHT_BRIGHT_PERCENT`, `BACKLIGHT_DIM_PERCENT`, `BACKLIGHT_AWAKE_MS`). If a power bank switches itself off while the screen is dim, raise `BACKLIGHT_DIM_PERCENT`: some banks cut out below 50–100 mA.

**BOOT button** (on the board): a press brightens the screen and, in Logging mode, shows the **details page** for 10 s: date, time with seconds, satellites tracked of visible, HDOP, latitude and longitude, points logged today, card state, when the trip meter was reset, and the firmware's git commit. Holding it for 2 s switches modes (see [Switching modes](#switching-modes)). It never logs anything. (Holding BOOT while resetting still starts the bootloader for flashing.)

The trip meter and today's point count survive a restart, because they're rebuilt from the log files on the card, including files already moved to `/uploaded`.

### Trip meter

The trip meter works like a car's: it counts from the last reset until you reset it again. **Only the phone app resets it.** The logger has no reset button. The app also keeps the all-time totals; the logger only shows the trip.

| Shows | Counts since the reset |
|---|---|
| each angler | catches, less the ones undone |
| distance | metres moved |
| time (h:mm) | time on the water |

Both follow the movement rule in [docs/metrics.md](docs/metrics.md), which the phone app uses too. A move only counts once the position has gone at least 25 m from where it was (more at a worse HDOP) and stayed out for 30 s, so GPS jitter while the logger sits still adds nothing. Time on the water runs from the first move to the last in each stretch of logging, so time at anchor between moves counts, but time on a desk, or waiting at the ramp before setting off, doesn't. A gap of over 15 minutes (logger off, in Transfer mode or without a fix) starts a new stretch, and neither the time nor the straight line across the gap counts.

The reset time is kept in `/trip.txt` on the card. At boot the logger rebuilds the meter from every log file since that date. The app can reset the meter while it's away from the logger: the reset is sent at the next connection and counts from the moment it was pressed. Details are in [docs/ble-protocol.md](docs/ble-protocol.md#trip-meter-v2).

### Switching modes

**Hold BOOT for 2 s** to switch between Logging and Transfer. The old mode switch still works if it's fitted (closed = Transfer); whichever happened last wins. Without it, the logger boots in Logging mode.

Transfer mode goes back to Logging by itself after 10 minutes with no phone connected (`TRANSFER_IDLE_MS`), so a logger left in Transfer doesn't miss a day's fishing.

### Transfer mode

Logging stops and Bluetooth starts advertising as **GPS Logger**. The screen shows:

- the Bluetooth state: Waiting for phone (orange border) or Connected (green border)
- the file being sent, with a progress bar
- how many files are left
- the last result

Catch buttons are ignored in this mode.

### Anglers

The logger knows up to 4 anglers, each with a name and a colour, in button order. The phone app sets them (BLE `SET_ANGLER`, protocol v4), or the console: `anglers Jase,blue Matt,orange`. They're saved in `/anglers.txt`; without that file the anglers are Jase (blue) and Matt (orange).

- Names are 1–12 characters: letters, digits, spaces, `-`, `.` and `'`. Colours are blue, orange, green, purple, teal and pink.
- Catches are logged by name (`Sam catch`), and the logger counts a catch for whichever angler has that name now. Renaming an angler starts their count on the logger again; the old name's catches stay in the logs.
- This board has 2 catch buttons (`ANGLER_BUTTON_PINS` in `config.h`). A 3rd or 4th angler shows on the screen, but needs a button wired before they can log a catch.

### Phone page

Web Bluetooth only works in **Chrome on Android**, and only on a page served over **HTTPS** (or from `localhost`). It doesn't work on iPhone.

1. Open the hosted page in Chrome on the phone.
2. Hold the logger's BOOT button for 2 s to switch to Transfer.
3. Tap **Connect** and pick **GPS Logger**.
4. Tap **Download all**, or **Download** on a single file. Tick **Also save the raw CSV** if you want the CSV as well as the GPX.

For each file, the page:

1. downloads the file and checks its CRC-32
2. converts it to GPX: track points, split into segments at gaps over 15 min, plus a waypoint named after the angler ("Jase catch") for each catch, leaving out catches undone in the same file
3. saves the files to Downloads
4. tells the logger, which moves the file to `/uploaded` on the card

A failed or interrupted file stays on the card. The first time it saves more than one file, Chrome may ask to allow multiple downloads.

#### Hosting the page

The page is published with GitHub Pages at **https://jasonshelley.github.io/gps-logger/**. On the phone, bookmark it or use **Add to Home screen**.

The workflow `.github/workflows/pages.yml` republishes the `web/` folder whenever a push to `main` changes it. The repository's Pages source is set to **GitHub Actions**.

To test a change locally before pushing, serve `web/` from the PC, for example with `python -m http.server 3000 --bind 127.0.0.1 --directory web`, and open `http://127.0.0.1:3000`. Chrome treats `localhost` and `127.0.0.1` as secure.

## Files on the card

| Path | What |
|---|---|
| `/gpsYYYYMMDD.csv` | Today's and earlier logs not yet transferred. Named by **Sydney local date** |
| `/gpsnodate.csv` | Only if a catch was pressed before the GPS had ever given the date |
| `/uploaded/` | Files the phone has confirmed |
| `/trip.txt` | The trip meter's reset time (`reset_utc=<seconds>`), written when the app resets the meter or erases the logs. Kept by `rm *` |
| `/anglers.txt` | The anglers in button order, one `name,colour` per line, written when the app sets them. Optional; kept by `rm *` and `erase-logs` |
| `/readme.txt` | Optional. Printed to the console at boot, and kept by `rm *` |

Each record goes in the file for its own local date, so a trip past midnight splits across two files. Times inside the file are UTC.

### CSV columns

The file starts with a header row. Fields have no quoting and there's no trailing comma. An empty field means "not available".

| Column | Example | Notes |
|---|---|---|
| `type` | `track` | `track`, `catch` or `undo` |
| `time_utc` | `2026-11-11T08:15:02Z` | ISO 8601 UTC. For a catch, the time of the press |
| `lat` | `-33.865143` | degrees, 6 dp |
| `lon` | `151.209900` | degrees, 6 dp |
| `alt_m` | `12.34` | metres above mean sea level |
| `speed_kmh` | `5.20` | km/h |
| `course_deg` | `123.45` | degrees true |
| `hdop` | `1.2` | |
| `sats_tracked` | `9` | |
| `sats_visible` | `14` | |
| `fix_quality` | `1` | GGA quality: 0 none, 1 GPS, 2 DGPS, … |
| `fix_mode` | `A` | RMC mode: A autonomous, D differential, E estimated, N none |
| `fix_age_s` | `2` | Catches only: how old the fix used for the position was, in seconds. `0` = current fix. Empty for track points |
| `comment` | `Jase catch` | `<name> catch` on catch rows; `<name> undo <time_utc of the catch>` on undo rows (just `<name> undo` if that catch had no time); empty on track rows |

A catch made with no fix since boot (and none in today's file) has an empty position. The GPX has no waypoint for it, and the page says so.

An **undo** row cancels one earlier catch: the one by the same angler at the time in its comment, or that angler's latest catch if there's no time. It has a time (when it was undone) but no position. It goes in the file for its own date, so an undo after midnight can be in the next day's file from the catch it cancels.

## Serial console

USB serial at 115200 baud. Type a command and press Enter. Lines over 96 characters are rejected.

| Command | What it does |
|---|---|
| `help` | Lists the commands |
| `status` | GPS comms, lock, fix mode and quality, satellites, HDOP, position, clock (UTC and local), card state, buffered and dropped rows, today's numbers, the trip meter, uptime, free heap |
| `ls` / `ls /uploaded` | Lists files with sizes |
| `cat <file>` | Prints a file |
| `tail <file> [n]` | Prints the last n lines (default 10) |
| `rm <file>` | Deletes a file |
| `rm *` | Deletes every file in `/` except `readme.txt`, `trip.txt` and `anglers.txt`, after you type `yes` |
| `erase-logs` | Deletes every log file in `/` and `/uploaded` and zeroes the trip meter, after you type `yes`. The same as the app's "reset all the data" (BLE `ERASE_LOGS`) |
| `df` | Card size, used and free |
| `anglers` | Lists the anglers in button order, with their colours and catches this trip |
| `anglers <name,colour> ...` | Sets 1–4 anglers, for example `anglers Jase,blue Matt,orange Sam,green`. The same as the app's `SET_ANGLER`. Names can't have spaces here (the app's can) |

File names without a leading `/` are in the root folder, for example `cat uploaded/gps20261111.csv`.

[tools/console.py](tools/console.py) runs commands from PowerShell without a serial monitor. It finds the logger by its USB ID (or takes `--port`). Opening the port resets the board, so it waits for the boot banner first:

```powershell
C:\pioenv\Scripts\python.exe tools\console.py status "tail trip.txt 5"
```

`--watch 120 --every 30` keeps printing for 2 minutes and sends `status` every 30 s; `--watch 15` on its own just shows the boot log. It doesn't answer `yes` for you: add `yes` as the next command if you mean it.

## Project layout

```
platformio.ini          build config (pinned platform and libraries)
include/config.h        pins and constants
include/lv_conf.h       LVGL 8.3 config
src/main.cpp            setup and main loop, mode switching
src/st7789.*            LCD driver (from Waveshare's demo)
src/lvgl_port.*         LVGL display glue
src/ui.*                logger and transfer screens
src/gps.*               UART1 + TinyGPSPlusPlus, fix filter, lock/comms state
src/clock.*             system clock from GPS, Sydney local time
src/track_logger.*      log rule, catches, buffer and flush, daily CSV, today's stats
src/trip_meter.*        trip meter: reset time in /trip.txt, rebuild from logs, live counts
src/move_meter.*        movement rule: distance moved and time on the water (docs/metrics.md)
src/log_reader.*        reads log CSV rows (for the rebuilds)
src/storage.*           SD mount/retry, listing, move to /uploaded
src/ble_transfer.*      NimBLE GATT transfer service
src/crc32.*             CRC-32 shared with the phone page
src/console.*           USB serial console
src/inputs.*            debounced buttons (press and hold) and switch
src/anglers.*           anglers' names and colours (/anglers.txt), catch and undo comments
web/index.html          phone page (Web Bluetooth, CSV → GPX)
docs/                   requirements, BLE protocol, movement and trip metrics
test/test_metrics/      native unit tests for the movement rule
test-data/              log fixtures for those tests (see its README)
tools/metrics.py        reference implementation of docs/metrics.md
tools/make_fixtures.py  makes the fixtures in test-data/
tools/pio.ps1           runs PlatformIO with this PC's settings
tools/fw_version.py     build step: puts the git commit in include/fw_version.h
tools/console.py        runs serial console commands from the command line
```

## Tests

The movement rule (`src/move_meter.cpp`) has unit tests that run on the PC, including the two log fixtures in `test-data/`:

```
pio test -e native
```

That needs a host C++ compiler (gcc or clang) on the PATH, and has to be run from the project folder so the tests find `test-data/`. The reference implementation gives the same numbers without a compiler:

```
python tools/metrics.py test-data/stationary-desk.csv test-data/moving-noisy.csv
```

## Not yet tested on hardware

`pio run` builds with no warnings in the project's own code, but none of it has run on the board yet. See the bottom of [docs/requirements.md](docs/requirements.md) for the list of things to check on first power-up.
