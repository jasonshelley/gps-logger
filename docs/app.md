# Catch Log: the Android app

Catch Log is the phone companion for the logger. It syncs the logger's files over Bluetooth LE, turns them into trips, and shows each trip on a map with a replay, the catches per angler, matching gallery photos and the conditions at each catch. It's phase 1 of [premium-proposal.md](premium-proposal.md).

- Flutter, Android only for now. Nothing in the code rules out iOS later.
- Local-first: SQLite on the phone, no account, no cloud.
- No API keys anywhere. Maps come from OpenFreeMap and weather from Open-Meteo, and both are free and keyless.

The code is in [`app/`](../app).

## Using it

1. Put the logger's switch on **Transfer** (IO3 to GND). Its screen says "Waiting for phone".
2. Open Catch Log and tap **Sync**. The first time, Android asks for **Nearby devices**. That permission is Bluetooth only: the scan is declared `neverForLocation`.
3. The app finds the logger, then downloads each file. For each file it checks the size and CRC-32, saves it, and only then sends CONFIRM, so the logger moves the file to `/uploaded`. A file that fails or is interrupted stays on the logger and comes across next time.
4. Trips appear on the home screen. Tap one for the map, replay, catches and conditions.
5. The **trip meter** at the top of the home screen counts catches, distance and time on the water since you last tapped **Reset**. The **All time** card below it never resets.

**Add sample trips** (⋮ menu, or the button on the empty screen) loads two days of made-up Sydney Harbour trips, for trying the app before the logger has had a GPS fix outdoors. They're dated 52 weeks back so they can't clash with real logs. **Remove sample trips** deletes only them.

## Building and running

### One-time setup (this PC)

Everything lives on short paths under `C:\src\tools`, because Windows long paths are off on this PC:

| Tool | Where | Notes |
|---|---|---|
| Flutter 3.47.9 stable | `C:\src\tools\flutter` | |
| Temurin JDK 17 | `C:\src\tools\jdk17` | `winget install EclipseAdoptium.Temurin.17.JDK --location C:\src\tools\jdk17` |
| Android SDK | `C:\src\tools\android` | cmdline-tools, platform-tools, build-tools 36, platforms 36 and 37.0, NDK 28.2, CMake 3.22 |
| Pub cache | `C:\src\tools\pub` | `PUB_CACHE` |
| Gradle home | `C:\src\tools\gradle` | `GRADLE_USER_HOME` |

`C:\src\tools\env.ps1` sets those variables and the `PATH`. Dot-source it in each new PowerShell window:

```powershell
. C:\src\tools\env.ps1
```

Flutter itself was pointed at the SDK and JDK once with `flutter config --android-sdk C:\src\tools\android --jdk-dir C:\src\tools\jdk17`.

Use **PowerShell**, not Git Bash.

The new Android SDK command-line tools (cmdline-tools 23) name packages with `/`, not `;`. For example: `sdkmanager "platforms/android-37.0"`.

### Run on the phone

With the S21 plugged in and USB debugging allowed:

```powershell
. C:\src\tools\env.ps1
cd C:\src\mine\gps-logger\app
flutter run
```

To build a debug APK only, use `flutter build apk --debug`. The first build downloads Gradle and the Android libraries, which takes several minutes.

### Tests

```powershell
flutter test
flutter analyze
```

The tests use the sample CSVs in `app/test/fixtures`. To regenerate those, run `python tool/make_fixtures.py` from `app/`.

`test/layout_test.dart` renders the home screen, every sync screen state, the trip stats, the catch cards and the replay banner at the S21's size (360 × 800 dp). It does this at font scales 1.0, 1.1 (the S21's setting), 1.3, 1.5 and 2.0, and fails on any overflow. The test font is wider than Roboto, so it's stricter than the phone. The trip screen as a whole isn't covered, because its map is a platform view.

### Build settings that differ from Flutter's template

- **AGP 9.5.1 and Gradle 9.8.2** instead of the template's AGP 9.1.0. API 37 ships as `platforms/android-37.0`, and AGP 9.1 can't find it.
- **`compileSdk = 37`**, because permission_handler needs it. `targetSdk` stays at Flutter's default.
- **Java 17 for all plugins.** maplibre_gl declares Java and Kotlin 21, but its code doesn't need more than 17, and this toolchain is JDK 17. The override is in `app/android/build.gradle.kts`. Remove it if the JDK moves to 21.

## Architecture

```
app/lib/
  core/            pure Dart, unit tested
    crc32.dart       CRC-32 (zlib), the same as the firmware and web page
    log_csv.dart     the logger CSV -> TrackPoint / CatchEvent
    trips.dart       trip splitting, route segments, stats, replay interpolation
    gpx.dart         GPX 1.1 export (matches the web page's output)
    photo_match.dart photos -> nearest catch by timestamp
    astro.dart       sunrise/sunset, sun altitude, moon phase (SunCalc formulas)
    conditions.dart  Open-Meteo URLs, parsing, per-catch conditions
  ble/
    protocol.dart    UUIDs, opcodes, command encoding, event decoding
    ble_link.dart    scan and GATT transport (universal_ble)
  sync/
    logger_session.dart  the protocol state machine over any transport
    sync_controller.dart the sync flow and its UI states
    permissions.dart     Android 12+ Bluetooth permissions
  data/
    database.dart    SQLite schema
    repository.dart  import, trips, queries, caches
  ui/              screens and widgets (Material 3)
```

### Sync

`LoggerSession` speaks [the protocol](ble-protocol.md) over a `LoggerTransport`. The real transport is Bluetooth LE through [universal_ble](https://pub.dev/packages/universal_ble), which is BSD licensed. The tests use `test/support/fake_logger.dart`, a pretend logger that also injects faults: dropped chunks, corrupted bytes, disconnects and stalls.

Connecting asks for MTU 247 and high connection priority, which gives 239-byte chunks. The session waits for END before it checks the size and the CRC. A 15 s stall watchdog sends ABORT.

`SyncController` runs the whole flow as a set of states, and each state has its own screen:

| State | When |
|---|---|
| needs permission, permission blocked | Nearby devices isn't allowed yet, or Android won't ask again |
| Bluetooth off | It carries on by itself once Bluetooth is on |
| scanning, not found | Searches for 12 s, then shows tips if nothing turned up |
| connecting, listing | |
| transferring | Progress for each file, the speed and the time left |
| done | Shows what arrived, and offers "View trip" |
| failed | What went wrong and what was kept |

### Data

| Table | What |
|---|---|
| `files` | One row per received file, keyed by (name, CRC). The raw CSV is kept in the app's documents folder (`logs/`), exactly as received |
| `points` | Track points, keyed by time in ms. Importing the same rows again does nothing, which matters because the logger re-sends a day's later rows as a new file with the same name |
| `catches` | Unique on (time, angler). Catches with no date have a null time and are shown apart from trips |
| `trips` | Derived after every import. A trip is a run of records with no gap longer than 45 min. Its id is its start time |
| `trip_conditions` | The Open-Meteo responses for each trip, cached so a trip opens offline |
| `settings` | Key-value settings, added in schema version 2: the trip meter's reset time, and a reset still to be sent to the logger |

How trip stats are worked out:

- **Distance** is the sum of haversine legs inside each route segment. Segments break at gaps over 15 min, the same rule as the GPX export. Legs implying more than 120 km/h count as GPS glitches and are skipped.
- **Moving time** counts the legs where the average speed is at least 2 km/h.

### Trip meter and totals

The top of the home screen works like a car's trip meter. It shows catches per angler, distance and time on the water since the last **Reset**. The card below it shows the all-time totals: catches per angler, distance, time on the water, trips, and fish in all.

- The reset time is stored in the `settings` table (schema version 2) as UTC milliseconds, rounded to the second. The meter is worked out from the synced data, so a reset works with no logger in reach.
- Trips that started after the reset count in full. A trip under way at the reset counts only from the reset on: its stats are recomputed from the points and catches after it.
- "Time on the water" adds up each trip's span, from its first record to its last.
- The totals include catches the logger made before it had the time. The meter leaves those out, because it can't tell whether they came before or after the reset.
- A reset is also queued for the logger, so its screen shows the same meter. At the next sync, after LIST and before the downloads, `sendQueuedMeterReset` sends it through the `LoggerMeter` interface ([logger_meter.dart](../app/lib/sync/logger_meter.dart)). The queue clears only once the logger accepts it. A reset that can't be sent stays queued and never fails the sync. If the phone is reset again before a sync, only the newest reset is sent.
- **Waiting on the firmware.** The meter commands will be documented in `docs/ble-protocol.md`. Until they are, the app uses `NoLoggerMeter`, which reports that the logger doesn't support them, so resets stay queued. Supporting them means writing a `LoggerMeter` that does two things: recognise a capable logger from its HELLO, and send the reset time (the logger counts from that time, whatever its own clock says). Then pass it to `SyncController`.

### Map and replay

- **Base map:** MapLibre ([maplibre_gl](https://pub.dev/packages/maplibre_gl)) with the OpenFreeMap `positron` style in light mode and `dark` in dark mode. The attribution button stays on the map, as OpenStreetMap requires.
- **Route:** short GeoJSON line features coloured by speed, from indigo when drifting to yellow when flat out. Each feature carries its end time.
- **Catch pins:** circles in each angler's colour: Jase orange, Matt fuchsia. Tapping a pin scrolls the sheet to that catch.
- **Replay:** a layer filter (`t <= now`) reveals the route and the pins as time passes, over a faded copy of the whole route. A boat marker moves along the route, interpolated between points. Each frame changes only filters and one point, so no route geometry is re-sent. Playback speed defaults to about 40 s for the whole trip and can be changed from 30× to 1200×. A banner and a haptic tap mark each catch.

### Photos

Photos need `READ_MEDIA_IMAGES`, or the user-selected subset on Android 14+. The trip screen explains why before it asks. Photos stay on the phone, and only their timestamps are read.

The app picks photos taken from 5 min before the trip to 30 min after it. Each photo goes to the catch made up to 20 min before it, or up to 3 min after it to allow for clock skew. Time before a catch counts double, so a photo goes to the catch it follows. Photos that don't match a catch are counted as "other photos from this trip".

### Conditions

- **Sun and moon** are calculated on the phone: sunrise and sunset, "40 min after sunrise", and the moon phase and illumination.
- **Weather** comes from Open-Meteo's forecast API for trips in the last 80 days, and from its archive API for older ones: wind and gusts in knots, direction, MSL pressure with its 3-hour trend, and air temperature.
- **Marine data** comes from Open-Meteo's marine API with `cell_selection=sea`: wave height, period and direction, and sea surface temperature.

The app makes one request of each kind per trip, at the middle of its catches, and caches the responses. Values are interpolated to each catch's minute. Inland water or no network gives a quiet "no data" with a Retry button.

## Tested on the real phone

On 2026-11-11, on a Galaxy S21 (SM-G991B, Android 15), with the logger on COM3 in Transfer mode:

- The app installed and ran with `flutter run`.
- Allowing Nearby devices worked.
- The scan found **GPS Logger** by its service UUID and connected.
- The MTU went to 247. HELLO came back as protocol v1 with 239-byte chunks.
- LIST reported `gps20261111.csv` (683 bytes).
- GET came through intact, with CRC `7ee26532` matching.
- The file was stored, and CONFIRM was accepted, so the logger moved the file to `/uploaded`.
- The file's 7 real track points became a trip, "Wed 11 Nov, 2:01 pm, 3 min, 134 m", on the home screen.
- The first attempt was closed after the import but before CONFIRM. The second sync recognised the file as already stored and only confirmed it, which is the designed recovery.
- That first attempt exposed two races in cancelling a sync, both now fixed (commit `b0bf3c0`). A cancel during the Bluetooth connect was missed. A cancel while a file was being saved could disconnect before CONFIRM. Now a file that has started saving always gets its CONFIRM before the run stops. This fix hasn't been run on the phone yet.
- The app restarting during testing was `flutter run` installing a new build (Android logs it as a force stop), not a crash. No Dart exception or native crash was logged.
- After the first sync the home screen didn't refresh. A `setState` call handed Flutter a Future. Debug builds reject that before redrawing, so after a database change home only caught up when something else redrew it. The layout test found this when the trip meter was added, and it's fixed.
- The trip screen's stats tiles overflowed by 5.9 px on the S21 (font scale 1.1). They now sit two to a row and size to their content. The layout test also found, and I fixed, overflows at larger fonts in the condition chips, the season card on home, the download ring, the trip title row and the replay banner. None of these fixes has been seen on the phone yet.

## What's next

- **Real trips.** Real files need a day on the water: long transfers (about 0.5 MB, 30–100 s), many catches, photos and conditions.
- **Catch details.** Species, length, kept or released, and notes, as the proposal describes.
- **Offline map packs** for the usual water. MapLibre supports offline regions.
- **Tides.** These need a licensed source (see the proposal's risks).
- **iOS.** Run `flutter create --platforms ios .` in `app/`, add the Bluetooth and photo usage strings, and test the background rules.
- **Automatic background sync** (milestone 4). It needs firmware changes, described below.

## Design: automatic background sync (milestone 4, not built)

The goal: the phone syncs when it comes near the logger, with nobody pressing anything.

### On the phone

1. **Pair once** with `CompanionDeviceManager.associate()`. Use an `AssociationRequest` with a `BluetoothLeDeviceFilter` on the service UUID `1f5f0001-…`, which brings up the system's own device picker. Association gives the app background privileges for this one device, with no location permission.
2. Implement a **`CompanionDeviceService`** and call `startObservingDevicePresence()`. Android 13+ wakes the service with `onDeviceAppeared` when the logger's advertisement is seen, even when the app isn't running.
3. In `onDeviceAppeared`, start a **foreground service** of type `connectedDevice`, which needs `FOREGROUND_SERVICE_CONNECTED_DEVICE`. It shows the notification "Syncing trip…" and runs the same `LoggerSession` code through a background Flutter engine or a headless isolate. When it finishes, it posts "Trip synced: 4 h 12 m, 23 km, 6 fish" and stops itself.
4. Add the manifest entries: `REQUEST_COMPANION_RUN_IN_BACKGROUND`, `REQUEST_COMPANION_USE_DATA_IN_BACKGROUND`, the service declaration with `BIND_COMPANION_DEVICE_SERVICE`, and `POST_NOTIFICATIONS`.

### What the firmware would need

Today the logger advertises only in Transfer mode, and logging stops while it does. For background sync:

1. **Advertise in Logging mode too.** Use a slow connectable advertisement, for example every 1–2 s, with the same service UUID. Advertise only when there's something to send, or only when the boat is stopped (speed below 2 km/h for 5+ min). That avoids radio use while fishing and lets the phone sync at the ramp.
2. **Say what's waiting, in the advertisement.** Add manufacturer data with a version byte, the number of files waiting, the total bytes waiting, and a "trip ended" flag. The phone can then skip connecting when there's nothing new. Use a test company ID (0xFFFF) for personal use.
3. **Serve files while logging.** GET of today's file has to be safe while new rows are being appended. Flush first, then send a snapshot up to the size reported in BEGIN. CONFIRM of today's file has to keep logging correctly: move the bytes sent so far to `/uploaded` and keep appending new rows to a fresh `/gpsYYYYMMDD.csv`. The existing append-on-move rule already handles the second half. Alternatively, never CONFIRM today's file until the day changes or the trip has ended.
4. **Add security, because it would always be advertising.** Require an LE Secure Connections bond before CONFIRM (and ideally GET). The logger could show a 6-digit passkey on its screen the first time. Store the bond in NVS. That stops a stranger's phone from emptying the card.
5. **Optionally, a status characteristic.** A read-only characteristic with today's catches, distance and battery would let the phone show "on the water" information without a transfer.
6. **Mind the power.** Advertising at 1–2 s intervals costs little next to the GPS. The logger should still stop advertising after, say, 10 min without a connection in Logging mode, until the next stop.

The protocol itself (HELLO, LIST, GET, CONFIRM) wouldn't change. The phone side already handles everything after the connection.
