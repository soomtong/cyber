#!/usr/bin/env python3
"""Makes cases for `time_zone_fuzz_run.cy`: what Python's `zoneinfo` says about instants and clock readings.

usage: time_zone_fuzz_gen.py <seed> <count> <out.json>

Both sides read the time zone database of the system, so the data is the same. A case has a zone and an
instant, with the offset, the abbreviation and the daylight saving flag there, and a clock reading in the zone
with the instants that `fold=0` and `fold=1` give for it. Half of the instants are near a transition.
The `time` module rounds an offset to the minute: a case with an offset that is not a whole minute (local mean
time) is left out.
"""
import json
import random
import sys
import zoneinfo
from datetime import datetime, timedelta, timezone

EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)
NAIVE_EPOCH = datetime(1970, 1, 1)
ALWAYS = [
    "America/New_York", "Europe/London", "Asia/Seoul", "Australia/Lord_Howe", "Africa/Casablanca",
    "America/St_Johns", "Pacific/Apia", "Asia/Kathmandu", "Europe/Dublin", "America/Sao_Paulo",
    "Pacific/Chatham", "Asia/Tehran", "Antarctica/Troll", "America/Nuuk", "Etc/GMT+5", "UTC",
]


def at(sec):
    return EPOCH + timedelta(seconds=sec)


def offset(zone, sec):
    return at(sec).astimezone(zone).utcoffset()


def near_transition(rng, zone):
    """An instant within a day of a transition, or a random one when the zone has none near."""
    lo = rng.randrange(-1_500_000_000, 6_000_000_000)
    hi = lo + 200 * 86400
    a, b = offset(zone, lo), offset(zone, hi)
    if a == b:
        return lo
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if offset(zone, mid) == a:
            lo = mid
        else:
            hi = mid
    return hi + rng.choice([0, -1, 1, rng.randrange(-90000, 90000), rng.randrange(-4000, 4000)])


def whole_minutes(delta):
    return delta is not None and delta.total_seconds() % 60 == 0


def main():
    seed, count, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    rng = random.Random(seed)
    names = sorted(zoneinfo.available_timezones())
    names = [n for n in names if "/" in n or n == "UTC"]
    cases = []
    while len(cases) < count:
        name = rng.choice(ALWAYS) if rng.randrange(3) == 0 else rng.choice(names)
        zone = zoneinfo.ZoneInfo(name)
        sec = near_transition(rng, zone) if rng.randrange(2) else rng.randrange(-2_000_000_000, 8_000_000_000)
        dt = at(sec).astimezone(zone)
        if not whole_minutes(dt.utcoffset()):
            continue
        # A clock reading near the instant, read both ways.
        local = dt.replace(tzinfo=None) + timedelta(seconds=rng.choice([0, 0, 1800, -1800, 3600, -3600, rng.randrange(-7200, 7200)]))
        first = local.replace(tzinfo=zone, fold=0)
        second = local.replace(tzinfo=zone, fold=1)
        if not whole_minutes(first.utcoffset()) or not whole_minutes(second.utcoffset()):
            continue
        local_sec = int((local - NAIVE_EPOCH).total_seconds())
        cases.append({
            "zone": name, "sec": sec,
            "off": int(dt.utcoffset().total_seconds()) // 60,
            "dst": bool(dt.dst()),
            "abbr": dt.tzname(),
            "text": dt.strftime("%Y-%m-%d %H:%M:%S"),
            "local": [local.year, local.month, local.day, local.hour, local.minute, local.second],
            "fold0": local_sec - int(first.utcoffset().total_seconds()),
            "fold1": local_sec - int(second.utcoffset().total_seconds()),
        })
    with open(out, "w") as f:
        json.dump(cases, f)


main()
