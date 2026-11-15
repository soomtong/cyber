#!/usr/bin/env python3
"""Makes cases for `time_fuzz_run.cy`: what Python's `datetime` says about random instants and offsets.

usage: time_fuzz_gen.py <seed> <count> <out.json>

A case has an instant (`sec`, `nsec`), an offset in minutes, the calendar fields that `datetime` gives at that
offset, the outputs of some `strftime` formats, and the result of a month shift (the day clamps to the end of
the month, which `datetime` has no function for: it is computed here with `calendar.monthrange`).
`strftime` is compared for years from 1000 only: the C library does not pad a shorter year the same everywhere.
"""
import calendar
import json
import random
import sys
from datetime import date, datetime, timedelta, timezone

MIN_SEC = -62135510400
MAX_SEC = 253402214399
EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)
FORMATS = [
    "%Y-%m-%dT%H:%M:%S",
    "%a %A %b %B %d %j",
    "%y %m %e|%I %p %M %S %f",
    "%G-W%V-%u %w",
    "%z|%H%%",
    "%d/%b/%Y:%H:%M:%S %z",
    "%F %T %R %D",
]
# Formats that hold every field, so that parsing gives the instant back.
ROUND_TRIP = [
    "%Y-%m-%d %H:%M:%S.%f %z",
    "%d/%b/%Y:%H:%M:%S.%f %z",
    "%A, %B %d %Y %I:%M:%S.%f %p %z",
    "%Y %j %H %M %S %f %z",
]


def rfc3339(dt, nsec, off):
    text = dt.strftime("%Y-%m-%dT%H:%M:%S") if dt.year >= 1000 else "%04d-%02d-%02dT%02d:%02d:%02d" % (
        dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second)
    if nsec:
        text += "." + ("%09d" % nsec).rstrip("0")
    if off == 0:
        return text + "Z"
    sign = "-" if off < 0 else "+"
    return text + "%s%02d:%02d" % (sign, abs(off) // 60, abs(off) % 60)


def shift_months(d, n):
    total = d.year * 12 + d.month - 1 + n
    y, m = divmod(total, 12)
    m += 1
    if y < 1 or y > 9999:
        return None
    return date(y, m, min(d.day, calendar.monthrange(y, m)[1])).isoformat()


def pick_sec(rng):
    kind = rng.randrange(10)
    if kind == 0:
        return rng.choice([MIN_SEC, MAX_SEC, 0, -1, 86399, 86400, -86400, -86401])
    if kind < 5:
        return rng.randrange(-2 * 10**9, 5 * 10**9)
    if kind < 7:
        # Around the end of February and of the year.
        y = rng.randrange(1, 9999)
        base = int((datetime(y, rng.choice([1, 3]), 1, tzinfo=timezone.utc) - EPOCH).total_seconds())
        return max(MIN_SEC, min(MAX_SEC, base + rng.randrange(-3 * 86400, 3 * 86400)))
    return rng.randrange(MIN_SEC, MAX_SEC + 1)


def main():
    seed, count, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    rng = random.Random(seed)
    cases = []
    for _ in range(count):
        sec = pick_sec(rng)
        usec = rng.choice([0, 0, 500000, rng.randrange(1000000)])
        off = rng.choice([0, 0, 540, 330, 345, -210, -720, 840, 1439, -1439, rng.randrange(-1439, 1440)])
        dt = (EPOCH + timedelta(seconds=sec, microseconds=usec)).astimezone(timezone(timedelta(minutes=off)))
        iso = dt.isocalendar()
        months = rng.choice([1, -1, 12, -12, rng.randrange(-30000, 30000), rng.randrange(-40, 40)])
        days = rng.randrange(-500, 500)
        other = dt.date() + timedelta(days=days) if 1 <= (dt.date().toordinal() + days) <= date.max.toordinal() else None
        case = {
            "sec": sec, "nsec": usec * 1000, "off": off,
            "fields": [dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second, dt.weekday(),
                       dt.timetuple().tm_yday, iso[0], iso[1]],
            "rfc3339": rfc3339(dt, usec * 1000, off),
            "months": months, "shifted": shift_months(dt.date(), months),
            "days": days, "other": other.isoformat() if other else None,
        }
        if dt.year >= 1000:
            case["formats"] = [[f, dt.strftime(f)] for f in FORMATS]
            case["round_trip"] = [[f, dt.strftime(f)] for f in ROUND_TRIP]
        cases.append(case)
    with open(out, "w") as f:
        json.dump(cases, f)


main()
