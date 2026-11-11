"""Makes the test fixtures in test-data/.

    python tools/make_fixtures.py moving test-data/moving-noisy.csv
    python tools/make_fixtures.py anonymise <raw log, kept OUTSIDE the repo> test-data/stationary-desk.csv

moving     A synthetic trip with known true distance and time on the water. The
           per-second fixes go through the logger's log rule (log_rule below,
           the same as src/track_logger.cpp), so the rows are the ones the
           logger would write.
anonymise  Moves a real log to open water in the Tasman Sea, keeping its shape:
           every point keeps its east/north offset in metres from the log's
           centre. Altitude becomes relative to the median. Nothing about the
           original position is kept. Never commit the raw file.
"""
import csv
import math
import os
import random
import statistics
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from metrics import MoveMeter  # noqa: E402

HEADER = ["type", "time_utc", "lat", "lon", "alt_m", "speed_kmh", "course_deg", "hdop",
          "sats_tracked", "sats_visible", "fix_quality", "fix_mode", "fix_age_s", "comment"]

# Open water, well away from any coast: the Tasman Sea, about 600 km east of Sydney.
DESK_CENTRE = (-36.5, 157.5)
MOVING_START = (-37.0, 158.0)
MOVING_T0 = int(datetime(2026, 11, 8, 20, 0, 0, tzinfo=timezone.utc).timestamp())

LOG_MIN_INTERVAL_S = 5         # moving: a point every 5 s
LOG_STATIONARY_INTERVAL_S = 60  # otherwise: a point a minute
LOG_MOVING_HOLD_S = 120        # "moving" lasts this long after the last confirmed move


def metres_per_degree(lat):
    return 111132.954 - 559.822 * math.cos(2 * math.radians(lat)), 111319.488 * math.cos(math.radians(lat))


def iso(t):
    return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class LogRule:
    """Which fixes the logger writes (src/track_logger.cpp, shouldLog)."""

    def __init__(self):
        self.detector = MoveMeter()
        self.last_logged = None
        self.last_move = None

    def should_log(self, t, lat, lon, hdop):
        moved = self.detector.add(t, lat, lon, hdop) > 0
        if moved:
            self.last_move = t
        if self.last_logged is None or moved:
            return True
        dt = t - self.last_logged
        moving = self.last_move is not None and t - self.last_move < LOG_MOVING_HOLD_S
        return (moving and dt >= LOG_MIN_INTERVAL_S) or dt >= LOG_STATIONARY_INTERVAL_S

    def logged(self, t):
        self.last_logged = t


def true_motion():
    """Yields (seconds since start, east_m, north_m, speed_kmh, course_deg, logger_on, phase)."""
    state = {"e": 0.0, "n": 0.0, "t": 0}

    def run(seconds, kmh, heading_fn, phase):
        for s in range(seconds):
            h = heading_fn(s)
            v = kmh / 3.6
            state["e"] += v * math.sin(math.radians(h))
            state["n"] += v * math.cos(math.radians(h))
            state["t"] += 1
            yield state["t"], state["e"], state["n"], kmh, h % 360, True, phase

    bend = 25 * math.sin(1500 / 200.0)
    yield from run(1500, 5.0, lambda s: 60 + 25 * math.sin(s / 200.0), "A motor out")
    yield from run(60, 5.0, lambda s: 60 + bend + 2.0 * s, "A motor out")  # a 120-degree turn
    yield from run(240, 5.0, lambda s: 180 + bend + 10 * math.sin(s / 60.0), "A motor out")
    yield from run(3600, 0.0, lambda s: 0.0, "B at anchor")
    yield from run(3600, 1.0, lambda s: 135 + 15 * math.sin(s / 900.0), "C drift 1 km/h")
    yield from run(1800, 5.0, lambda s: 270 + 20 * math.sin(s / 300.0), "D motor back")
    for _ in range(1200):  # logger switched to Transfer for 20 minutes
        state["t"] += 1
        yield state["t"], state["e"], state["n"], 0.0, 0.0, False, "gap"
    state["e"] += 300.0  # and it comes back on 300 m away
    yield from run(600, 5.0, lambda s: 30 * math.sin(s / 150.0), "E motor again")


def make_moving(out_path, seed=7):
    rnd = random.Random(seed)
    a = math.exp(-1 / 30.0)  # noise correlation: time constant 30 s
    sd = 4.0                 # metres per axis, clipped to an 8 m radius below
    ne = nn = 0.0
    m_lat, m_lon = metres_per_degree(MOVING_START[0])
    rule = LogRule()
    rows = []
    truth = {}
    prev = None
    catches = {MOVING_T0 + 1800 + 1200: "Jase catch", MOVING_T0 + 1800 + 2700: "Matt catch"}
    for s, e, n, kmh, course, on, phase in true_motion():
        t = MOVING_T0 + s
        ne = a * ne + math.sqrt(1 - a * a) * rnd.gauss(0, sd)
        nn = a * nn + math.sqrt(1 - a * a) * rnd.gauss(0, sd)
        r = math.hypot(ne, nn)
        if r > 8.0:
            ne, nn = ne * 8.0 / r, nn * 8.0 / r
        if not on:
            prev = None
            continue
        if prev is not None:
            truth.setdefault(phase, 0.0)
            truth[phase] += math.hypot(e - prev[0], n - prev[1])
        prev = (e, n)
        lat = round(MOVING_START[0] + (n + nn) / m_lat, 6)
        lon = round(MOVING_START[1] + (e + ne) / m_lon, 6)
        hdop = round(rnd.uniform(0.9, 1.6), 1)
        speed = max(0.0, kmh + rnd.gauss(0, 0.3))
        sats = rnd.randint(8, 11)
        fields = [iso(t), "%.6f" % lat, "%.6f" % lon, "%.2f" % rnd.uniform(-2, 2), "%.2f" % speed,
                  "%.2f" % course, "%.1f" % hdop, str(sats), str(sats + rnd.randint(1, 4)), "1", "A"]
        if rule.should_log(t, lat, lon, hdop):
            rule.logged(t)
            rows.append(["track"] + fields + ["", ""])
        if t in catches:
            rows.append(["catch"] + fields + ["0", catches[t]])
    with open(out_path, "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(HEADER)
        w.writerows(rows)
    total = sum(truth.values())
    print("%s: %d rows" % (out_path, len(rows)))
    for k, v in truth.items():
        print("  true distance %-15s %6.0f m" % (k, v))
    print("  true distance total           %6.0f m" % total)


def anonymise(raw_path, out_path):
    with open(raw_path, newline="") as f:
        rows = list(csv.DictReader(f))
    pts = [r for r in rows if r["lat"] and r["lon"]]
    lat0 = statistics.fmean(float(r["lat"]) for r in pts)
    lon0 = statistics.fmean(float(r["lon"]) for r in pts)
    alts = [float(r["alt_m"]) for r in rows if r["alt_m"]]
    alt0 = statistics.median(alts) if alts else 0.0
    m_lat0, m_lon0 = metres_per_degree(lat0)
    m_lat1, m_lon1 = metres_per_degree(DESK_CENTRE[0])
    for r in pts:
        north = (float(r["lat"]) - lat0) * m_lat0
        east = (float(r["lon"]) - lon0) * m_lon0
        r["lat"] = "%.6f" % (DESK_CENTRE[0] + north / m_lat1)
        r["lon"] = "%.6f" % (DESK_CENTRE[1] + east / m_lon1)
    for r in rows:
        if r["alt_m"]:
            r["alt_m"] = "%.2f" % (float(r["alt_m"]) - alt0)
    with open(out_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=HEADER, lineterminator="\n")
        w.writeheader()
        w.writerows(rows)
    print("%s: %d rows, centred on %s" % (out_path, len(rows), DESK_CENTRE))


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "moving":
        make_moving(sys.argv[2])
    elif len(sys.argv) == 4 and sys.argv[1] == "anonymise":
        anonymise(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
