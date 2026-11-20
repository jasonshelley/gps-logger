# Bluetooth LE transfer protocol

Version 4. The firmware side is in `src/ble_transfer.cpp`. The phone side is in `web/index.html` (file transfer only) and the Android app in `app/`.

Version 2 added the trip meter commands (METER, METER_RESET and the METER event). Version 3 added ERASE_LOGS and the ERASED event. Version 4 adds the anglers: GET_ANGLERS, SET_ANGLER and the ANGLER event. Every earlier message is unchanged, so an older client works with a newer logger. See [Version history](#version-history).

The logger is a GATT server that advertises only in Transfer mode, as `GPS Logger`. One phone can connect at a time. There is no pairing or bonding, so anyone within range can connect while the logger is in Transfer mode.

## Service and characteristics

| Role | UUID | Properties |
|---|---|---|
| Service | `1f5f0001-56c8-49fb-9d0c-055269d0a2e3` | Primary, and named in the advertisement so the page can filter on it |
| RX: commands from the phone | `1f5f0002-56c8-49fb-9d0c-055269d0a2e3` | Write, Write Without Response. Up to 96 bytes |
| TX: events and data to the phone | `1f5f0003-56c8-49fb-9d0c-055269d0a2e3` | Notify. Up to 245 bytes |

The advertisement carries the flags and the 128-bit service UUID. The name goes in the scan response, because both together don't fit in 31 bytes.

The logger asks for an ATT MTU of 247. File data goes in chunks of `MTU − 8` bytes, capped at 240: 3 bytes are the ATT header and 5 are the DATA header. With the default MTU of 23 it still works, at 15 bytes per chunk.

## Message format

Every message starts with a one-byte opcode. Integers are unsigned little-endian. Names are ASCII, aren't null-terminated, and run to the end of the message.

### Commands (phone → RX)

| Op | Name | Payload | Reply |
|---|---|---|---|
| `0x01` | HELLO | none | HELLO |
| `0x02` | LIST | none | one FILE per log file, then LIST_END |
| `0x03` | GET | `name` | BEGIN, then DATA, ..., then END |
| `0x04` | CONFIRM | `crc:u32`, `name` | CONFIRMED, or ERROR |
| `0x05` | ABORT | none | none. Stops the file being sent |
| `0x06` | METER (v2) | none | METER |
| `0x07` | METER_RESET (v2) | `reset:u32` (UTC seconds since 1970) | METER, or ERROR |
| `0x08` | ERASE_LOGS (v3) | the 4 ASCII bytes `ERAS` (`45 52 41 53`) | ERASED then METER, or ERROR. See [Erasing the logs](#erasing-the-logs-v3) |
| `0x09` | GET_ANGLERS (v4) | none | one ANGLER per angler. See [Anglers](#anglers-v4) |
| `0x0A` | SET_ANGLER (v4) | `index:u8`, `count:u8`, `colour:u8`, `name` | nothing until the last one; then one ANGLER per angler and a METER, or ERROR |

### Events (TX → phone)

| Op | Name | Payload |
|---|---|---|
| `0x81` | HELLO | `version:u8` (4), `chunk:u16` (data bytes per DATA message at the current MTU) |
| `0x82` | FILE | `size:u32`, `name` |
| `0x83` | LIST_END | `count:u16` |
| `0x84` | BEGIN | `size:u32`, `name` |
| `0x90` | DATA | `offset:u32`, then file bytes |
| `0x85` | END | `size:u32`, `crc:u32` |
| `0x86` | CONFIRMED | `name` (now in `/uploaded`) |
| `0x87` | METER (v2) | `reset:u32`, `catches1:u16`, `catches2:u16`, `distance_m:u32`, `water_s:u32`, `flags:u8`. 18 bytes. See [Trip meter](#trip-meter-v2) |
| `0x88` | ERASED (v3) | `deleted:u16`, `failed:u16`, `flags:u8`. 6 bytes. See [Erasing the logs](#erasing-the-logs-v3) |
| `0x89` | ANGLER (v4) | `index:u8`, `count:u8`, `buttons:u8`, `colour:u8`, `catches:u16`, `name`. At most 19 bytes. See [Anglers](#anglers-v4) |
| `0xEE` | ERROR | `code:u8`, then a short ASCII message |

### Error codes

| Code | Meaning |
|---|---|
| 1 | Unknown command |
| 2 | Bad file name: not `gps*.csv`, or contains a path, `..` or a non-printable character |
| 3 | File not found |
| 4 | Busy: a file is being sent. Only ABORT, METER and CONFIRM for a different file are accepted |
| 5 | SD card not available, or the trip reset couldn't be saved to it. After ERASE_LOGS it means nothing was erased |
| 6 | Read error while sending, or while checking the CRC |
| 7 | The CRC in CONFIRM doesn't match the file on the card, so the file is kept |
| 8 | Moving the file to `/uploaded` failed, so the file is kept |
| 9 | Message too short |
| 10 | ERASE_LOGS without the bytes `ERAS` (v3). Nothing was erased |
| 11 | SET_ANGLER with a bad name or colour, a count outside 1–4, an index out of order, or two anglers with the same name (v4). Nothing changed; start again at index 0 |

## Which files

LIST reports root-level files named `gps*.csv`, which means the daily logs (`gpsYYYYMMDD.csv`) plus `gpsnodate.csv` if a catch was made before the GPS knew the date. Files in `/uploaded` and other files aren't listed, and GET and CONFIRM refuse them.

## A transfer

```mermaid
sequenceDiagram
    participant P as Phone page
    participant L as Logger
    P->>L: (connect, enable notifications on TX)
    P->>L: HELLO
    L-->>P: HELLO v1, chunk 239
    P->>L: LIST
    L-->>P: FILE 51234 gps20261110.csv
    L-->>P: FILE 8210 gps20261111.csv
    L-->>P: LIST_END 2
    P->>L: GET gps20261110.csv
    L-->>P: BEGIN 51234 gps20261110.csv
    L-->>P: DATA @0 (239 bytes)
    L-->>P: DATA @239 ...
    L-->>P: END 51234, crc 0x1c291ca3
    Note over P: check size and CRC-32, make GPX, save
    P->>L: CONFIRM 0x1c291ca3 gps20261110.csv
    Note over L: check CRC against the card, move to /uploaded
    L-->>P: CONFIRMED gps20261110.csv
```

- DATA messages arrive in order, with no gaps. The phone checks that each `offset` equals the bytes received so far.
- The CRC is standard CRC-32, the same as zlib, PNG and Ethernet: reflected, polynomial `0xEDB88320`, initial value and final XOR `0xFFFFFFFF`. The CRC of `The quick brown fox jumps over the lazy dog` is `0x414fa339`.
- The phone sends CONFIRM only after it has checked the CRC and saved the files. The logger checks the CRC again against the file on the card before it moves anything, using the CRC from the send if the file's size hasn't changed since. A file is only ever moved after a confirmed, matching transfer.
- If the phone disconnects mid-file, or sends ABORT, the file stays where it is and nothing is moved.

## Moving to `/uploaded`

On a confirmed transfer, `/<name>` moves to `/uploaded/<name>`.

If `/uploaded/<name>` already exists, the new rows are appended to it without their header line, and `/<name>` is deleted. This happens when the same day was transferred earlier, logging carried on, and then that day was transferred again. `/uploaded` then holds the whole day in one file. The phone's second download only holds the rows logged since the first one, and Chrome saves it as `gpsYYYYMMDD (1).gpx`.

At boot the logger rebuilds today's catch counts and distance from both `/uploaded/gpsYYYYMMDD.csv` and `/gpsYYYYMMDD.csv`, so a transfer during the day doesn't reset them.

## Trip meter (v2)

The logger keeps a trip meter like a car's. It counts from a reset time until the next reset. Only the app resets it: the device has no reset button. The logger screen shows the meter. All-time totals are the app's job.

### What it counts

From the reset time `reset` (UTC) onwards:

| Field | Meaning |
|---|---|
| `catches1`, `catches2` | Anglers 1 and 2: catch rows whose `time_utc` is at or after `reset`, less the ones undone. ANGLER events carry every angler's count (v4) |
| `distance_m` | Metres moved, by the movement rule in [metrics.md](metrics.md) |
| `water_s` | Time on the water in seconds, by the same rule |

Both come from the track rows at or after `reset`, using the movement rule in **[metrics.md](metrics.md)**. The app must use that rule for its own figures. In short: only points with HDOP ≤ 5 count. A move counts once the position has stayed at least max(25 m, 30 m × HDOP) from the last counted position for 30 s. Time on the water runs from each segment's first move to its last, so time at anchor between moves counts. A gap of over 15 minutes between points starts a new segment, and neither the time nor the straight line across the gap counts. That's the same 15-minute rule the phone page uses to split GPX track segments.

So GPS jitter while the logger sits still, on a desk or at the berth, adds nothing to either figure. The first row at or after `reset` starts a segment.

Counts are rebuilt from the log files (see below). So deleting a log file from the card with `rm` removes its rows from the meter at the next rebuild.

### METER_RESET semantics

`METER_RESET reset` means: **the meter counts from time `reset`**. The app supplies the time, and it's the source of truth.

- **Queued resets work.** The app can record a reset while it's disconnected and send it at the next connection. The logger rebuilds the meter from its logs since `reset`, so catches and track logged between `reset` and the moment the command arrives still count. That's the same result as if the reset had arrived instantly.
- **Idempotent.** If `reset` equals the current reset time, nothing changes and the logger just replies with METER. Resending a reset whose reply was lost is safe.
- **Last write wins.** A different `reset`, earlier or later than the current one, replaces it. The app should send only its latest reset.
- `reset = 0` means "never reset": the meter counts every log on the card.
- A `reset` later than the logger's clock is accepted as given. The meter then counts nothing until that time.
- While a file is being sent, METER_RESET gets ERROR 4 (busy). METER always works.

The logger flushes its log buffer, saves `reset` to `/trip.txt`, rebuilds the meter and replies with METER. If the card can't be written, it replies ERROR 5 and the old reset stays in force.

### The METER event

| Offset | Field | Type | Notes |
|---|---|---|---|
| 0 | op | u8 | `0x87` |
| 1 | `reset` | u32 | The reset time in force, UTC seconds. 0 = never reset |
| 5 | `catches1` | u16 | Angler 1's catches since `reset` (stops at 65535). v2 and v3 called it `jase` |
| 7 | `catches2` | u16 | Angler 2's catches since `reset`, 0 if there's only one angler. v2 and v3 called it `matt` |
| 9 | `distance_m` | u32 | Metres, rounded |
| 13 | `water_s` | u32 | Seconds |
| 17 | `flags` | u8 | bit 0: **incomplete**. The card couldn't be read for the last rebuild, so the numbers may be low; the logger retries when the card is back. bit 1: **clock not set**. The logger hasn't had GPS time since boot. Other bits are 0 |

Example: reset 2026-11-11 08:00:00 UTC (`1794384000`), angler 1 (Jase) 3, angler 2 (Matt) 1, 12 345 m, 3 h 25 min (12 300 s), no flags:

```
87 80 20 f4 6a 03 00 01 00 39 30 00 00 0c 30 00 00 00
```

### Where it's stored and how it's rebuilt

- `/trip.txt` holds `reset_utc=<seconds>` and a comment line. A save writes `/trip.tmp` first and then swaps it in. If power fails mid-swap, the logger reads `/trip.tmp` at the next boot. With no file, `reset` is 0. The console's `rm *` keeps `trip.txt`.
- At boot (before the GPS has the time; the rebuild doesn't need it) and after a reset, the logger reads every `gpsYYYYMMDD.csv` dated on or after the reset's Sydney local date. It reads them in date order, `/uploaded/` part first and then the root folder's, since transferred files move to `/uploaded`. Files dated before the reset's local date can't contain anything after it, because each row goes in the file for its own local date.
- Catch rows with no time (`gpsnodate.csv`, made before the GPS ever had the date) count live but aren't recounted after a restart, because there's no way to tell whether they came after the reset.
- After the rebuild, every point and catch logged updates the meter straight away.
- The rebuild reads every file since the reset. If the meter goes months without a reset, boot takes longer: roughly a second per few MB of logs.

### Example exchange

```mermaid
sequenceDiagram
    participant A as App
    participant L as Logger
    A->>L: HELLO
    L-->>A: HELLO v2, chunk 239
    A->>L: METER
    L-->>A: METER reset=1794200000 jase=5 matt=2 ...
    Note over A: the user pressed Reset at 08:00 UTC while disconnected
    A->>L: METER_RESET 1794384000
    L-->>A: METER reset=1794384000 jase=1 matt=0 ...
    Note over A: reply lost, so it sends again
    A->>L: METER_RESET 1794384000
    L-->>A: METER reset=1794384000 (unchanged)
```

## Erasing the logs (v3)

`ERASE_LOGS` wipes the logger's data, for the app's "reset all the data". The app sends it only during a live connection, after the user has confirmed, and never queues it.

Command, 5 bytes:

```
08 45 52 41 53        ERASE_LOGS "ERAS"
```

The four bytes after the opcode must be the ASCII `ERAS` (as a u32 little-endian that's `0x53415245`). Anything else gets ERROR 10 and nothing is erased; fewer than 4 bytes get ERROR 9. That way a stray or corrupted write can't erase anything.

The logger then:

1. Drops the rows still in its RAM buffer and zeroes today's numbers, so nothing erased is written back afterwards.
2. Deletes every log file, `gps*.csv` (including `gpsnodate.csv`), in the root folder and in `/uploaded`. Other files stay: `readme.txt` and anything else that isn't a log. `/trip.txt` is rewritten in the next step.
3. Resets the trip meter to the logger's current UTC time if it has had GPS time since boot, or to 0 if not. 0 means "count every log", which is zero now that there are none. `/trip.txt` is written with the new time.
4. Rebuilds the meter, so it reads zero, and replies:

ERASED, 6 bytes:

| Offset | Field | Type | Notes |
|---|---|---|---|
| 0 | op | u8 | `0x88` |
| 1 | `deleted` | u16 | Log files deleted (stops at 65535) |
| 3 | `failed` | u16 | Log files that couldn't be deleted. They're still on the card, and listed by the next LIST |
| 5 | `flags` | u8 | bit 0: `/trip.txt` couldn't be written. The meter is zero now, but after a restart it would count from the old reset time; with the logs gone, that's still zero unless some files failed. Other bits are 0 |

Then the METER event with the new reset time and zero counts (`flags` bit 1 is set if the logger has no GPS time).

- **Idempotent.** Erasing an empty card replies `ERASED 0 0` and a zero METER. With GPS time, each erase moves the reset time to now, which still reads zero.
- While a file is being sent, it gets ERROR 4 (busy). If the card isn't available, ERROR 5, and nothing is erased or reset.
- Logging carries on normally afterwards. Nothing logs in Transfer mode anyway, so the first new rows come when the switch goes back to Logging.
- The logger screen shows zero catches and a zero trip straight away, and the transfer screen shows no files left.

Example: 4 files erased, none failed, then the meter reset to 2026-11-11 08:00:00 UTC with no flags:

```
88 04 00 00 00 00
87 80 20 f4 6a 00 00 00 00 00 00 00 00 00 00 00 00 00
```

The console has the same erase for bench use: `erase-logs`, then `yes`.

## Anglers (v4)

The logger knows 1 to 4 anglers, in button order: button 1 logs catches for angler 1 (index 0). Each has a name and a colour. They're kept on the card in `/anglers.txt`; without it they're Jase (blue) and Matt (orange). The screen shows each angler's catches since the trip reset, with the name in their colour.

**Names** are 1–12 ASCII characters: letters, digits, spaces, `-`, `.` and `'`, with no space at either end. Two anglers can't have the same name (ignoring case).

**Colours:**

| Value | Colour | RGB |
|---|---|---|
| 0 | blue | `#2196F3` |
| 1 | orange | `#FF5722` |
| 2 | green | `#4CAF50` |
| 3 | purple | `#9C27B0` |
| 4 | teal | `#009688` |
| 5 | pink | `#E91E63` |

### The ANGLER event

GET_ANGLERS, and a successful SET_ANGLER, send one ANGLER per angler, index 0 first. Each fits a 20-byte notification, so it works at the default MTU.

| Offset | Field | Type | Notes |
|---|---|---|---|
| 0 | op | u8 | `0x89` |
| 1 | `index` | u8 | 0-based, in button order |
| 2 | `count` | u8 | How many anglers there are, so the client knows when it has them all |
| 3 | `buttons` | u8 | How many catch buttons the logger has (2 on this board). An angler with `index >= buttons` is shown but can't log a catch yet |
| 4 | `colour` | u8 | See the table above |
| 5 | `catches` | u16 | This angler's catches since the trip reset, less the ones undone (stops at 65535) |
| 7 | `name` | ASCII | The rest of the message, 1–12 bytes |

### SET_ANGLER

Send one SET_ANGLER per angler, index 0 to count − 1, in order: `index:u8`, `count:u8`, `colour:u8`, then the name. Each fits a 20-byte write. Index 0 starts a new set. The logger checks each one as it arrives and replies ERROR 11 straight away if one is bad; the set is then dropped, and nothing has changed.

When the last one arrives, the logger saves the set to `/anglers.txt`, recounts the trip meter, and replies with an ANGLER for each angler and then a METER. If the card can't be written, it replies ERROR 5 and the old anglers stay. A file being sent (ERROR 4) also rejects it.

**Catches belong to a name.** The logs say `Jase catch`, so the logger counts a catch for whichever angler has that name now. Renaming an angler starts their count on the logger again; the old name's catches stay in the logs under the old name.

Example: set Jase (blue) and Sam (green):

```
0a 00 02 00 4a 61 73 65     SET_ANGLER index 0, count 2, blue, "Jase"
0a 01 02 02 53 61 6d        SET_ANGLER index 1, count 2, green, "Sam"
```

The logger replies `89 00 02 02 00 03 00 4a 61 73 65` (Jase, 3 catches), `89 01 02 02 02 00 00 53 61 6d` (Sam, none yet), then METER.

### Undo

Holding a catch button for 2 s undoes that angler's latest catch since the trip reset. The logger appends an `undo` row whose comment names the catch: `Jase undo 2026-11-20T03:12:44Z`, or `Jase undo` when that catch had no time. The catch row stays. Every count the logger sends (METER, ANGLER) already leaves undone catches out. A client reading the CSV must do the same: an undo row cancels that angler's catch at that time, or their latest catch if there's no time. The undo can be in a later file than the catch, if it was made after midnight. See README "CSV columns".

## Version history

| Version | Change |
|---|---|
| 1 | File transfer: HELLO, LIST, GET, CONFIRM, ABORT |
| 2 | Trip meter: METER (`0x06`), METER_RESET (`0x07`), METER event (`0x87`). Nothing in v1 changed. A client can check `version >= 2` in HELLO before using the meter, since a v1 logger answers METER with ERROR 1 (unknown command) |
| 2 (revised) | `distance_m` and `water_s` now follow the movement rule in [metrics.md](metrics.md) instead of summing every pair of consecutive points, which counted GPS jitter. The message formats didn't change, so the version number didn't either. A logger with the earlier firmware reports the larger, jitter-inflated figures |
| 3 | ERASE_LOGS (`0x08`) and the ERASED event (`0x88`), and error 10. Nothing in v1 or v2 changed. Check `version >= 3` in HELLO before sending ERASE_LOGS: a v2 logger answers it with ERROR 1 (unknown command) |
| 4 | Anglers: GET_ANGLERS (`0x09`), SET_ANGLER (`0x0A`), the ANGLER event (`0x89`) and error 11. METER's layout is unchanged, but its two counts are now anglers 1 and 2, whatever their names. Logs can hold `undo` rows, and every count leaves undone catches out. Check `version >= 4` in HELLO before sending GET_ANGLERS or SET_ANGLER: a v3 logger answers them with ERROR 1 |

## Flow control

The logger sends DATA notifications as fast as NimBLE has buffers, up to 16 each time through the main loop. When NimBLE runs out of buffers, `notify()` returns false and the logger tries the same chunk again on the next pass. A notification that NimBLE has accepted reaches the phone in order, unless the link drops, in which case the transfer fails and is retried from the start. Nothing is acknowledged per chunk, because the CRC at the end covers the whole file.

Expect roughly 5 to 20 KB/s, depending on the phone's connection interval. A full day's log is about 0.5 MB.
