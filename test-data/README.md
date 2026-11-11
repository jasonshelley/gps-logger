# Test fixtures

Log files in the logger's CSV format, used by the movement and trip metrics tests (`pio test -e native`, `test/test_metrics`) and as a check for the phone app. The rule they test is in [docs/metrics.md](../docs/metrics.md).

| File | What it is | Expected |
|---|---|---|
| `stationary-desk.csv` | A real log: the logger sat on a desk indoors on 2026-11-11 for 1.6 h (313 points, HDOP 2.2–5.0). Its position wandered up to 100 m and the GPS speed read 2–14 km/h. The old trip meter counted 3231 m and 3939 s from it | Under 50 m and about 0 s on the water. Today's rule gives 0 m and 0 s |
| `moving-noisy.csv` | Synthetic, made by `tools/make_fixtures.py moving` (seed 7). See below | Within 5% of the true 6831 m, and the hour at anchor counted in time on the water. Today's rule gives 6667 m (−2.4%) and 11 205 s |

## stationary-desk.csv is moved

The real log was recorded at a private address. Before it was added here, every point was moved to open water in the Tasman Sea, about 600 km east of Sydney, centred on 36.5° S 157.5° E. Each point keeps its east and north offset in metres from the log's centre, so the shape and size of the wander are unchanged. Altitude was made relative to the median. Nothing else was changed. The original file isn't in this repository, and must never be added.

`tools/make_fixtures.py anonymise <raw> <out>` does the move.

## moving-noisy.csv

Per-second fixes go through the logger's log rule, so the rows are what the logger would write. The noise is correlated (30 s time constant), about 4 m per axis and never more than 8 m. HDOP is 0.9–1.6. It starts at 2026-11-08 20:00 UTC, near 37° S 158° E.

| Phase | True motion | True distance |
|---|---|---|
| A | 30 min motoring at 5 km/h, with gentle curves and a 120° turn | 2499 m |
| B | 1 h at anchor (a catch for each angler) | 0 m |
| C | 1 h drifting at 1 km/h | 1000 m |
| D | 30 min motoring back at 5 km/h | 2500 m |
| gap | 20 min with the logger in Transfer mode; it comes back on 300 m away | not counted |
| E | 10 min motoring at 5 km/h | 832 m |
| | | **6831 m** |

True time on the water is 3 h for A to D (the hour at anchor included) plus 10 min for E: 11 400 s.

To check a file with the reference implementation:

```
python tools/metrics.py test-data/stationary-desk.csv test-data/moving-noisy.csv
```
