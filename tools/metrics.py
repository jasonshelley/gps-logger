"""Reference implementation of the movement and trip metrics in docs/metrics.md.

The firmware (src/move_meter.cpp) and the phone app must give the same numbers
as this file for the same log rows. Run it on log files to see what the logger
would show:

    python tools/metrics.py test-data/stationary-desk.csv test-data/moving-noisy.csv

Files are read in the order given, as one stream of rows (pass a day's
/uploaded part before its root-folder part).
"""
import csv
import math
import sys
from datetime import datetime, timezone

MAX_HDOP = 5.0          # points with a higher (or missing) HDOP are ignored
MOVE_MIN_M = 25.0       # the movement threshold is never less than this
MOVE_PER_HDOP_M = 30.0  # ... and grows with HDOP: max(25, 30 x HDOP) metres
CONFIRM_S = 30          # a move counts once the position has stayed out that long
SEGMENT_GAP_S = 900     # a longer gap between counted points starts a new segment

EARTH_RADIUS_M = 6371009.0  # mean Earth radius, as TinyGPSPlusPlus uses


def distance_m(lat1, lon1, lat2, lon2):
    """Great-circle distance (the atan2 form TinyGPSPlus::distanceBetween uses)."""
    delta = math.radians(lon1 - lon2)
    sdlong, cdlong = math.sin(delta), math.cos(delta)
    lat1, lat2 = math.radians(lat1), math.radians(lat2)
    slat1, clat1 = math.sin(lat1), math.cos(lat1)
    slat2, clat2 = math.sin(lat2), math.cos(lat2)
    delta = (clat1 * slat2) - (slat1 * clat2 * cdlong)
    delta = delta * delta
    delta += (clat2 * sdlong) ** 2
    delta = math.sqrt(delta)
    denom = (slat1 * slat2) + (clat1 * clat2 * cdlong)
    return math.atan2(delta, denom) * EARTH_RADIUS_M


def threshold_m(hdop):
    return max(MOVE_MIN_M, MOVE_PER_HDOP_M * hdop)


class MoveMeter:
    """Distance moved and time on the water from a stream of track points."""

    def __init__(self):
        self.distance_m = 0.0
        self._closed_water_s = 0
        self._last_t = None      # time of the last counted point
        self._anchor = None      # (lat, lon) of the last counted position
        self._out_since = None   # time the position first left the anchor's circle
        self._seg_first = None   # when the segment's first move started
        self._seg_last = None    # when the segment's last move was counted

    @property
    def water_s(self):
        open_s = self._seg_last - self._seg_first if self._seg_first is not None else 0
        return self._closed_water_s + open_s

    def add(self, t, lat, lon, hdop):
        """Feed one track point (UTC seconds). Returns the metres added (0 if none)."""
        if hdop is None or not (hdop <= MAX_HDOP):
            return 0.0
        if self._last_t is None or t < self._last_t or t - self._last_t > SEGMENT_GAP_S:
            # New segment: close the old one, anchor here, add nothing.
            if self._seg_first is not None:
                self._closed_water_s += self._seg_last - self._seg_first
            self._seg_first = self._seg_last = None
            self._anchor = (lat, lon)
            self._out_since = None
            self._last_t = t
            return 0.0
        self._last_t = t
        d = distance_m(self._anchor[0], self._anchor[1], lat, lon)
        if d < threshold_m(hdop):
            self._out_since = None
            return 0.0
        if self._out_since is None:
            self._out_since = t
        if t - self._out_since < CONFIRM_S:
            return 0.0
        # Confirmed move.
        self.distance_m += d
        if self._seg_first is None:
            self._seg_first = self._out_since
        self._seg_last = t
        self._anchor = (lat, lon)
        self._out_since = None
        return d


def parse_time(s):
    return int(datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp())


def read_rows(paths):
    for p in paths:
        with open(p, newline="") as f:
            for r in csv.DictReader(f):
                yield r


def meter_for(paths, reset_utc=0):
    """Returns (distance_m, water_s, jase, matt) for the rows since reset_utc."""
    m = MoveMeter()
    jase = matt = 0
    for r in read_rows(paths):
        if not r["time_utc"]:
            continue
        t = parse_time(r["time_utc"])
        if t < reset_utc:
            continue
        if r["type"] == "track":
            if r["lat"] and r["lon"] and r["hdop"]:
                m.add(t, float(r["lat"]), float(r["lon"]), float(r["hdop"]))
        elif r["type"] == "catch":
            jase += r["comment"].startswith("Jase")
            matt += r["comment"].startswith("Matt")
    return m.distance_m, m.water_s, jase, matt


if __name__ == "__main__":
    for path in sys.argv[1:]:
        d, w, j, mt = meter_for([path])
        print("%s: %.0f m, %d s on the water (%d:%02d), Jase %d, Matt %d" % (
            path, d, w, w // 3600, w % 3600 // 60, j, mt))
