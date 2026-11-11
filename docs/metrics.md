# Movement and trip metrics

This is the definition of **distance moved** and **time on the water**. The logger uses it for the trip meter, today's distance and the log rule. The phone app must use it too, so that both show the same numbers for the same log rows.

- Firmware: [`src/move_meter.cpp`](../src/move_meter.cpp) (plain C++, shared by everything on the logger).
- Reference implementation: [`tools/metrics.py`](../tools/metrics.py). When in doubt, it's the spec. Run it on a log file to see what the logger would show.
- Tests: [`test/test_metrics`](../test/test_metrics/test_main.cpp) (`pio test -e native`) and the fixtures in [`test-data/`](../test-data/README.md).

## Why

The first trip meter added up the distance between every pair of consecutive track points. GPS positions wander even when the logger isn't moving, so a logger left on a desk all day showed 3.2 km and 1 h 05 min on the water. Indoors, the position on that desk wandered up to 100 m from its centre, at 2 to 14 km/h of reported GPS speed, for hours. The rule below counts movement only when the position leaves a circle around where it was and stays out, and it ignores GPS speed.

## Inputs

Track rows from the log CSV (`type` = `track`), in time order: `time_utc`, `lat`, `lon` and `hdop`, **as written in the file** (6 decimals for lat/lon, 1 for HDOP). The logger feeds its live meters the same rounded values, so a live meter, a rebuild from the card and the app all see identical numbers.

Rows with an empty `time_utc`, `lat`, `lon` or `hdop` are skipped. Catch rows don't affect distance or time.

## Constants

| Name | Value | Meaning |
|---|---|---|
| `MAX_HDOP` | 5.0 | Points with HDOP over this are ignored completely |
| `MOVE_MIN_M` | 25 m | The movement threshold is never smaller than this |
| `MOVE_PER_HDOP_M` | 30 m | The threshold for a point is `max(25, 30 × hdop)` metres |
| `CONFIRM_S` | 30 s | The position has to stay outside the threshold this long |
| `SEGMENT_GAP_S` | 900 s | A gap over 15 min between counted points starts a new segment |
| Earth radius | 6 371 009 m | For the distance formula below |

**D_MOVE**, the movement threshold, is `max(25 m, 30 m × HDOP)` of the point being tested. That's 25 m up to HDOP 0.8, 30 m at HDOP 1.0, 60 m at HDOP 2.0 and 150 m at HDOP 5.0. GPS error grows with HDOP, and the desk log's HDOP was 2.2 to 5.0 while out on the water it's usually near 1.

## Distance formula

Great-circle distance, in the atan2 form TinyGPS++ uses (`TinyGPSPlus::distanceBetween` in TinyGPSPlusPlus 0.0.4):

```
Δλ = radians(lon1 − lon2)
φ1 = radians(lat1),  φ2 = radians(lat2)
y  = sqrt( (cos φ1·sin φ2 − sin φ1·cos φ2·cos Δλ)² + (cos φ2·sin Δλ)² )
x  = sin φ1·sin φ2 + cos φ1·cos φ2·cos Δλ
d  = atan2(y, x) × 6371009
```

Haversine with the same radius agrees to well under a millimetre at these distances. Use double precision.

## The rule

The meter keeps an **anchor**, the last counted position. It processes points one at a time:

```
for each track point p (time t, lat, lon, hdop), in file order:
    if hdop > 5 (or missing):            skip p entirely
    if no previous counted point, or t < last_t, or t − last_t > 900:
        # a new segment
        close the current segment's time on the water (see below)
        anchor = p;  out_since = none;  last_t = t
        continue                          # no distance for the jump
    last_t = t
    d = distance(anchor, p)
    if d < max(25, 30 × hdop):
        out_since = none                  # back inside: forget the excursion
        continue
    if out_since is none:
        out_since = t                     # just left the circle
    if t − out_since < 30:
        continue                          # not out long enough yet
    # a move
    distance += d
    if the segment has no move yet: seg_first = out_since
    seg_last = t
    anchor = p;  out_since = none
```

Some details:

- "Last counted point" means the last point with HDOP ≤ 5. Ignored points don't count towards the gap.
- A move adds the straight-line distance from the anchor to the confirming point. The points in between aren't added. The anchor then jumps to that point, and the next move is measured from there.
- Every point must stay outside the circle for the 30 seconds. One point back inside resets `out_since`, even if the next point is outside again.
- Each point is tested against its own HDOP's threshold.

## Time on the water

For each segment: **from when its first move started (`seg_first`, the time the position first left the anchor's circle for that move) to its last move (`seg_last`)**. A segment with no move counts 0. Time on the water is the sum over all segments.

So time spent at anchor between moves counts, because it's between the segment's first and last move. A logger that sits still all day counts nothing, and so does time before the first move or after the last one, such as waiting at the ramp. Time across a gap of over 15 min (logger off, in Transfer mode, or no good fix) doesn't count.

Keeping a running total needs only: the closed segments' total, and the current segment's `seg_first` and `seg_last`.

## Where the logger uses it

| Use | Points fed | Notes |
|---|---|---|
| Trip meter (`METER` event, logger screen) | Logged track rows with `time_utc` ≥ the reset time | Rows before the reset are skipped, so the first row at or after it starts a segment. Rebuilt at boot from `/uploaded/gpsYYYYMMDD.csv` then `/gpsYYYYMMDD.csv` for each day since the reset, in date order, then kept up to date as rows are logged. See [ble-protocol.md](ble-protocol.md#trip-meter-v2). |
| Today's distance (console `status`) | Today's logged track rows | A fresh meter each local day, so a move across midnight starts again in the new day. |
| Log rule | Every good fix, about once a second | A separate meter, used only to decide what to log (below). It isn't shown anywhere. |

The app should compute its figures from the logged rows, the same way as the trip meter: one meter over the rows in time order, starting a new segment at the first row it uses.

## Logging

The logger writes a track point for a good fix (HDOP ≤ 5) when:

1. it's the first since boot, or
2. the log rule's meter (above, fed every good fix) confirms a move on this fix, or
3. we're **moving**, meaning the log rule's meter confirmed a move in the last 120 s, and 5 s have passed since the last logged point, or
4. 60 s have passed since the last logged point.

GPS speed isn't used. A logger sitting still, however much its position wanders, writes one point a minute, and those points don't add distance. While motoring there's a point every 5 s. A slow drift logs a point every 5 s for 2 minutes after each move, and one a minute otherwise.

`config.h` has the times: `LOG_MIN_INTERVAL_MS`, `LOG_STATIONARY_INTERVAL_MS` and `LOG_MOVING_HOLD_MS`.

## Results on the fixtures

| Fixture | What it is | Distance | Time on the water |
|---|---|---|---|
| `stationary-desk.csv` | The real desk log from 2026-11-11 (313 points over 1.6 h, indoors, HDOP 2.2–5.0), moved to open water | **0 m** (the old rule: 3231 m) | **0 s** (the old rule: 3939 s) |
| `moving-noisy.csv` | Synthetic, ±8 m noise: 30 min at 5 km/h, 1 h at anchor, 1 h drifting at 1 km/h, 30 min at 5 km/h, a 20 min gap, 10 min at 5 km/h | **6667 m** of a true 6831 m (−2.4%) | **11 205 s** (3:06:45). The true figure is 11 400 s (3:10), including the hour at anchor |

The drift hour on its own gives 978 m of a true 1000 m. Twelve different noise seeds give −2.5% to −1.3% on distance.

How much margin is left on the desk log: it still gives 0 m with 25 m × HDOP instead of 30, or with 15 s instead of 30. 20 m × HDOP gives 284 m. A fixed threshold, without the HDOP scaling, needed 80 m to reach 0 with the same 30 s, because the indoor wander is that large.

## Known limits

- **The end of each run is lost.** When the boat stops, the last partial step, less than the threshold (30 m at HDOP 1), isn't counted. That's up to about 30 m per stop on the water.
- **Tight turns are cut.** Moves are straight lines between points 50–80 m apart at 5 km/h, so a zigzag smaller than that is shortened. Gentle trolling curves lose very little.
- **Moves start a little late.** A move is counted 30 s after it starts, and time on the water starts when the position left the circle. On the fixture, time on the water comes out about 3 minutes short over 3 hours.
- **Rounding.** The firmware uses double precision, like Python and Kotlin/Java. A point almost exactly on a threshold could in theory fall on different sides in different languages. With these fixtures the C++ tests expect the reference's numbers exactly.
- A logger left somewhere with worse jitter than the desk (for example deeper indoors with HDOP under 2.2 but big multipath errors) could still count a little.

## Changing the rule

The constants are in `src/move_meter.h` and `tools/metrics.py`. Change both, regenerate the moving fixture (`python tools/make_fixtures.py moving test-data/moving-noisy.csv`), update the expected numbers in `test/test_metrics/test_main.cpp` and the tables above, and tell the app side.
