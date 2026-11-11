# ESP32-C6 fishing GPS logger

A handheld GPS logger on a Waveshare ESP32-C6-LCD-1.47. It records the boat's track to an SD card, and two buttons ("Jase" and "Matt") mark each catch. A switch puts it into Transfer mode, where a phone downloads the logs over Bluetooth LE and saves them as GPX.

- Requirements and decisions: [docs/requirements.md](docs/requirements.md)
- Bluetooth protocol: [docs/ble-protocol.md](docs/ble-protocol.md)
- Phone page: [web/index.html](web/index.html)
- Pins and tuning constants: [include/config.h](include/config.h)

## Hardware

| Part | Notes |
|---|---|
| Waveshare ESP32-C6-LCD-1.47 | ESP32-C6 with in-package flash (the schematic says C6FH4, 4 MB; Jason's unit is a C6FH8, 8 MB). 172 × 320 ST7789 LCD, microSD slot, USB-C. The build uses a 4 MB layout, which runs on either |
| GPS receiver | Any NMEA receiver at 9600 baud, 8N1 |
| 2 momentary buttons | "Jase" and "Matt" |
| 1 two-position switch | Logging / Transfer |
| microSD card | FAT32 |
| USB power bank | Powers it through the USB-C port |

### Wiring

All three inputs are active low: wire each between its GPIO and GND. The internal pull-ups are on, so no resistors are needed.

| Function | GPIO | Header U2 pin | Connect to |
|---|---|---|---|
| Jase button | **1** | 14 (IO1) | button → GND |
| Matt button | **2** | 15 (IO2) | button → GND |
| Mode switch | **3** | 16 (IO3) | switch → GND. Closed = **Transfer**, open = **Logging** |
| GPS TX → ESP RX | **19** | 3 (IO19) | GPS module TX |
| ESP TX → GPS RX | **18** | 2 (IO18) | GPS module RX |
| GPS power | – | 12 (3V3) or 10 (5V) | whichever the GPS module needs |
| Ground | – | 11 (GND) | GPS GND, button and switch commons |

Header pin numbers are from Waveshare's schematic (`ESP32-C6-LCD-1.47_schemetics.pdf`). Header U2 is pins 1–18: BOOT(IO9), IO18, IO19, IO20, IO23, USB_N, USB_P, RXD, TXD, 5V, GND, 3V3, IO0, IO1, IO2, IO3, IO4, IO5. Check this against the silkscreen on your board before you solder.

**Why GPIO 1, 2 and 3:** the schematic shows nothing else on them. They aren't strapping pins (on the ESP32-C6 those are 4, 5, 8, 9 and 15). GPIO 0 and 1 can take a 32 kHz crystal, but this board doesn't fit one, so GPIO 1 is free.

**Don't use these:**

- 4 and 5: SD CS and MISO, which are also strapping pins. The old sketch had the buttons here.
- 6, 7, 14, 15, 21, 22: the LCD.
- 8: the RGB LED.
- 9: BOOT.
- 12 and 13: USB.

IO0, IO20, IO23 and the UART0 TXD/RXD pads are spare.

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

A clean build uses about 28% of RAM (91 KB) and 1.07 MB of the 3 MB app partition.

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

### Logging mode (switch open)

The logger reads the GPS and writes a track point:

- every 5 s or every 10 m, whichever comes first, while moving
- every 60 s while stationary, meaning under 2 km/h and less than 10 m from the last point
- only when HDOP is 5 or less

Pressing **Jase** or **Matt** writes a catch record straight away at the current position, and shows "Jase catch!" or "Matt catch!" for 3 s. If the current fix is poor, the catch uses the last good fix and records how old it is. The banner turns red with "NOT SAVED" if the card write failed.

Buffered track points reach the card every 10 s, and also straight away on a catch or a mode switch. A power cut loses at most about 10 s of track.

### Logger screen

From the top:

- **Sats arc**: satellites tracked. Green = lock, orange = searching, red = none.
- **HDOP arc**: a fuller arc means better accuracy. Green when HDOP is 5 or less.
- Course in degrees and as a compass point, then speed in km/h. These show `--` when HDOP is over 5.
- Local date and time (Sydney), with AEST or AEDT beside the time.
- Today's catches: `Jase n` and `Matt n`.
- Today's distance along the logged track.
- Status line: `OK`, `No fix` or `SD error`, plus the points logged today.
- The border is green while bytes are arriving from the GPS, and red when they've stopped.

Catch counts, points and distance survive a restart. Once the GPS gives the date, they're rebuilt from today's file on the card, including any part of today already moved to `/uploaded`.

### Transfer mode (switch closed)

Logging stops and Bluetooth starts advertising as **GPS Logger**. The screen shows:

- the Bluetooth state: Waiting for phone (orange border) or Connected (green border)
- the file being sent, with a progress bar
- how many files are left
- the last result

Catch buttons are ignored in this mode.

### Phone page

Web Bluetooth only works in **Chrome on Android**, and only on a page served over **HTTPS** (or from `localhost`). It doesn't work on iPhone.

1. Open the hosted page in Chrome on the phone.
2. Put the logger's switch on Transfer.
3. Tap **Connect** and pick **GPS Logger**.
4. Tap **Download all**, or **Download** on a single file. Tick **Also save the raw CSV** if you want the CSV as well as the GPX.

For each file, the page:

1. downloads the file and checks its CRC-32
2. converts it to GPX: track points, split into segments at gaps over 15 min, plus a waypoint named "Jase catch" or "Matt catch" for each catch
3. saves the files to Downloads
4. tells the logger, which moves the file to `/uploaded` on the card

A failed or interrupted file stays on the card. The first time it saves more than one file, Chrome may ask to allow multiple downloads.

#### Hosting the page

The page is one static file, so any HTTPS host works. GitHub Pages is the simplest free option:

1. Make a GitHub repository (it can hold only `index.html`) and push `web/index.html` to it.
2. Turn on Pages in **Settings → Pages** (deploy from branch `main`, folder `/`).
3. Open `https://<user>.github.io/<repo>/` on the phone and bookmark it, or use **Add to Home screen**.

Nothing has been published yet. For a quick test from a PC, `npx serve web` gives `http://localhost:3000`, which Chrome treats as secure.

## Files on the card

| Path | What |
|---|---|
| `/gpsYYYYMMDD.csv` | Today's and earlier logs not yet transferred. Named by **Sydney local date** |
| `/gpsnodate.csv` | Only if a catch was pressed before the GPS had ever given the date |
| `/uploaded/` | Files the phone has confirmed |
| `/readme.txt` | Optional. Printed to the console at boot, and kept by `rm *` |

Each record goes in the file for its own local date, so a trip past midnight splits across two files. Times inside the file are UTC.

### CSV columns

The file starts with a header row. Fields have no quoting and there's no trailing comma. An empty field means "not available".

| Column | Example | Notes |
|---|---|---|
| `type` | `track` | `track` or `catch` |
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
| `comment` | `Jase catch` | `Jase catch` or `Matt catch` on catch rows, empty on track rows |

A catch made with no fix since boot (and none in today's file) has an empty position. The GPX has no waypoint for it, and the page says so.

## Serial console

USB serial at 115200 baud. Type a command and press Enter. Lines over 96 characters are rejected.

| Command | What it does |
|---|---|
| `help` | Lists the commands |
| `status` | GPS comms, lock, fix mode and quality, satellites, HDOP, position, clock (UTC and local), card state, buffered and dropped rows, today's numbers, uptime, free heap |
| `ls` / `ls /uploaded` | Lists files with sizes |
| `cat <file>` | Prints a file |
| `tail <file> [n]` | Prints the last n lines (default 10) |
| `rm <file>` | Deletes a file |
| `rm *` | Deletes every file in `/` except `readme.txt`, after you type `yes` |
| `df` | Card size, used and free |

File names without a leading `/` are in the root folder, for example `cat uploaded/gps20261111.csv`.

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
src/track_logger.*      log rule, catches, buffer and flush, daily CSV, stats rebuild
src/storage.*           SD mount/retry, listing, move to /uploaded
src/ble_transfer.*      NimBLE GATT transfer service
src/crc32.*             CRC-32 shared with the phone page
src/console.*           USB serial console
src/inputs.*            debounced buttons and switch
web/index.html          phone page (Web Bluetooth, CSV → GPX)
docs/                   requirements and protocol
```

## Not yet tested on hardware

`pio run` builds with no warnings in the project's own code, but none of it has run on the board yet. See the bottom of [docs/requirements.md](docs/requirements.md) for the list of things to check on first power-up.
