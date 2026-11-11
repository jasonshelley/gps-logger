"""Generates sample logger CSVs for tests and for trying the app without a GPS fix.

Run from app/:  python tool/make_fixtures.py
Writes test/fixtures/*.csv in the logger's format (README "CSV columns"),
following the logger's own rules: a point every 5 s or 10 m while moving,
every 60 s while stopped. Times are UTC; files are named by Sydney date.
"""
import math
import os
import random
from datetime import datetime, timedelta, timezone

HEADER = ("type,time_utc,lat,lon,alt_m,speed_kmh,course_deg,hdop,sats_tracked,"
          "sats_visible,fix_quality,fix_mode,fix_age_s,comment")
OUT = os.path.join(os.path.dirname(__file__), "..", "test", "fixtures")
R = 6371008.8


def dist(a, b):
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * R * math.asin(math.sqrt(h))


def bearing(a, b):
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    y = math.sin(lo2 - lo1) * math.cos(la2)
    x = math.cos(la1) * math.sin(la2) - math.sin(la1) * math.cos(la2) * math.cos(lo2 - lo1)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def row(kind, t, p, speed, course, age="", comment="", rnd=None):
    sats = rnd.randint(8, 12)
    return ",".join([
        kind, iso(t), f"{p[0]:.6f}", f"{p[1]:.6f}", f"{rnd.uniform(1, 4):.2f}",
        f"{speed:.2f}", f"{course:.2f}", f"{rnd.uniform(0.7, 1.6):.1f}", str(sats),
        str(sats + rnd.randint(2, 5)), "1", "A", str(age), comment])


def simulate(start, plan, seed):
    """plan: list of ("go", (lat, lon), kmh) | ("drift", minutes) | ("catch", angler)
    | ("off", minutes)  -> (rows, end_time)"""
    rnd = random.Random(seed)
    t = start
    pos = plan[0][1]
    rows = []
    last_logged = None
    for step in plan[1:]:
        if step[0] == "go":
            target, kmh = step[1], step[2]
            course = bearing(pos, target)
            while dist(pos, target) > 5:
                v = kmh * rnd.uniform(0.85, 1.1)
                d = min(v / 3.6 * 5, dist(pos, target))
                brg = math.radians(bearing(pos, target))
                dlat = d * math.cos(brg) / R
                dlon = d * math.sin(brg) / (R * math.cos(math.radians(pos[0])))
                pos = (pos[0] + math.degrees(dlat), pos[1] + math.degrees(dlon))
                t += timedelta(seconds=5)
                course = bearing(pos, target)
                rows.append(row("track", t, pos, v, course, rnd=rnd))
                last_logged = t
        elif step[0] == "drift":
            end = t + timedelta(minutes=step[1])
            while t < end:
                t += timedelta(seconds=60)
                pos = (pos[0] + rnd.uniform(-2e-5, 2e-5), pos[1] + rnd.uniform(-2e-5, 2e-5))
                rows.append(row("track", t, pos, rnd.uniform(0.2, 1.5), rnd.uniform(0, 359), rnd=rnd))
                last_logged = t
        elif step[0] == "catch":
            ct = t + timedelta(seconds=rnd.randint(5, 50))
            rows.append(row("catch", ct, pos, 0.5, 0, age=0, comment=f"{step[1]} catch", rnd=rnd))
        elif step[0] == "stale_catch":
            ct = t + timedelta(seconds=30)
            age = int((ct - last_logged).total_seconds())
            rows.append(row("catch", ct, pos, 0.5, 0, age=age, comment=f"{step[1]} catch", rnd=rnd))
        elif step[0] == "off":
            t += timedelta(minutes=step[1])
    return rows, t


RAMP = (-33.86870, 151.26190)       # Rose Bay, off Lyne Park
OUT_OF_BAY = (-33.86200, 151.26700)
CHANNEL = (-33.85000, 151.27000)
CHOWDER = (-33.83850, 151.25850)   # off Chowder Bay
OBELISK = (-33.83500, 151.26350)
NIELSEN = (-33.85350, 151.26750)


def write(name, rows):
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, name), "w", newline="\n") as f:
        f.write(HEADER + "\n")
        for r in rows:
            f.write(r + "\n")


def main():
    # Sat 8 Nov 2026, 05:40 AEDT = 7 Nov 18:40 UTC. A morning trip with a
    # 20-minute gap where the logger was off, and a catch on a stale fix.
    rows, _ = simulate(datetime(2026, 11, 7, 18, 40, tzinfo=timezone.utc), [
        ("start", RAMP),
        ("drift", 4),
        ("go", OUT_OF_BAY, 8), ("go", CHANNEL, 22), ("go", CHOWDER, 18),
        ("drift", 25), ("catch", "Jase"), ("drift", 14), ("catch", "Matt"), ("drift", 30),
        ("catch", "Jase"), ("drift", 10),
        ("go", OBELISK, 10), ("drift", 20), ("off", 20), ("stale_catch", "Matt"),
        ("drift", 35), ("catch", "Jase"), ("drift", 15), ("catch", "Jase"),
        ("go", NIELSEN, 20), ("drift", 25), ("catch", "Matt"),
        ("go", OUT_OF_BAY, 20), ("go", RAMP, 7), ("drift", 3),
    ], seed=8)
    write("gps20261108.csv", rows)

    # Mon 10 Nov: two trips in one day (morning and evening).
    morning, _ = simulate(datetime(2026, 11, 9, 19, 5, tzinfo=timezone.utc), [
        ("start", RAMP), ("go", OUT_OF_BAY, 8), ("go", NIELSEN, 20), ("drift", 50),
        ("catch", "Matt"), ("drift", 20), ("go", RAMP, 18),
    ], seed=10)
    evening, _ = simulate(datetime(2026, 11, 10, 6, 10, tzinfo=timezone.utc), [
        ("start", RAMP), ("go", OUT_OF_BAY, 8), ("go", CHOWDER, 24), ("drift", 40),
        ("catch", "Jase"), ("drift", 12), ("catch", "Jase"), ("drift", 18), ("go", RAMP, 22),
    ], seed=11)
    write("gps20261110.csv", morning + evening)

    # Catches pressed before the GPS ever had the date: no time, no position.
    with open(os.path.join(OUT, "gpsnodate.csv"), "w", newline="\n") as f:
        f.write(HEADER + "\n")
        f.write("catch,,,,,,,,,,,,,Jase catch\n")
        f.write("catch,,,,,,,,,,,,,Matt catch\n")


if __name__ == "__main__":
    main()
