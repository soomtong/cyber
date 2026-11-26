--| Instants, calendar dates, durations and time zones.
--| A `Time` is an instant, a `DateTime` is an instant seen at a UTC offset or in a time zone, a `Date` is a
--| calendar day and a `Duration` is a length of time. An offset is in minutes east of UTC. A `Zone` is a time zone
--| of the IANA database, read from the system. The calendar is the proleptic Gregorian one, years 1 to 9999,
--| without leap seconds.
--| Sample usage:
--| ```cy
--| use time
--|
--| dt := time.parse('2026-11-15T10:22:03+09:00')!
--| print(dt.utc().format())                      --> 2026-11-15T01:22:03Z
--| print(dt.format('%Y/%m/%d %H:%M'))!           --> 2026/11/15 10:22
--| print(dt.add_months(3)!.date().format())      --> 2027-02-15
--| print(time.date(2027, 1, 1)! - dt.date())     --> 47
--|
--| start := time.now()
--| print((time.now() - start) < time.seconds(1)) --> true
--| print(start.to_offset(330)!.format())         --> the current time at +05:30
--|
--| ny := time.zone('America/New_York')!
--| print(dt.to_zone(ny).format('%F %T %Z')!)     --> 2026-11-14 20:22:03 EST
--| ```

--| The least and the greatest UTC offset, in minutes: -23:59 and +23:59.
const MinOffset = -1439
const MaxOffset = 1439

-const NsPerSec = 1000000000
-const SecsPerDay = 86400
-- Days from 1970-01-01 to 0001-01-01 and to 9999-12-31.
-const MinDay = -719162
-const MaxDay = 2932896
-- 0001-01-02T00:00:00Z and 9999-12-30T23:59:59Z. A day is left at each end, so that the local date of a `Time`
-- is in the range of `Date` at any offset.
-const MinSec = -62135510400
-const MaxSec = 253402214399
-- The longest `Duration` in seconds: the days from 0001-01-01 to 9999-12-31.
-const MaxDurSec = 315537897600
-- An offset argument that stands for "the text must have one".
-const NoOffset = 1000000

--| Where and why parsing failed. `pos` is a byte offset into the input, or into the format for `error.Format`.
type Diag:
    msg str = ''
    pos int = 0

--| An instant: seconds and nanoseconds since 1970-01-01T00:00:00Z.
--| The range is 0001-01-02T00:00:00Z to 9999-12-30T23:59:59.999999999Z.
type Time:
    -sec  int
    -nsec int

--| An instant seen at a UTC offset, or in a time zone. `<`, `<=`, `>`, `>=` and `-` look at the instant only.
--| `==` looks at the offset and the zone too: two values of the same instant at different offsets or in different
--| zones are not `==`. Compare `a.time() == b.time()` for the instant.
type DateTime:
    -sec  int
    -nsec int
    -off  int
    -tz   Zone = {}

--| A calendar day, 0001-01-01 to 9999-12-31.
type Date:
    -days int

--| A length of time with nanosecond resolution, negative or positive. A day is 86400 seconds.
type Duration:
    -sec  int
    -nsec int

--| A time zone: the UTC offsets of a place over time, with its daylight saving time.
--| `time.zone(name)` reads one from the time zone database of the system.
type Zone:
    -- 0: none (the value of a `DateTime` at a fixed offset), 1: a TZif file, 2: a rule only.
    -kind    int = 0
    -name_   str = ''
    -- The TZif file. The transitions are read from it when they are asked for, so that two zones compare by
    -- their bytes with `==`.
    -data    str = ''
    -- The bytes of a transition time, 4 or 8, and the places of the tables in `data`.
    -wide    int = 8
    -ntrans  int = 0
    -ntypes  int = 0
    -p_trans int = 0
    -p_idx   int = 0
    -p_types int = 0
    -p_abbr  int = 0
    -rule    Rule = {}
    -- Whether `name_` is a name of the time zone database: the zone came from `time.zone` or `time.local`.
    -db      bool = false

-- The rule of a POSIX `TZ` string such as `EST5EDT,M3.2.0,M11.1.0`. A TZif file ends with one, for the time after
-- its last transition. Offsets are in minutes east of UTC.
-type Rule:
    has      bool = false
    std_off  int = 0
    std_abbr str = ''
    dst      bool = false
    dst_off  int = 0
    dst_abbr str = ''
    start    RuleDay = {}
    end      RuleDay = {}

-- When daylight saving time starts or ends in a year. kind 0: `Mm.w.d`, the weekday `d` (0 is Sunday) of week `w`
-- (5 is the last) of month `m`. kind 1: `Jn`, day `d` of the year from 1, without February 29.
-- kind 2: `n`, day `d` of the year from 0. `secs` is the time of day in seconds, -167 to 167 hours.
-type RuleDay:
    kind int = 0
    m    int = 0
    w    int = 0
    d    int = 0
    secs int = 7200

-- What a zone says about an instant.
-type ZoneInfo:
    off  int
    dst  bool
    abbr str

--| What to do with a date and time of day that a zone has twice or not at all.
--| When clocks go back, an hour comes twice: `earlier` and `compatible` take the first, `later` the second.
--| When clocks go forward, an hour is skipped: `later` and `compatible` take the time that the clock would
--| show had it not been set (02:30 becomes 03:30), `earlier` the time an hour before (01:30).
--| `reject` returns `error.Ambiguous` or `error.Skipped`.
type Disambiguation enum:
    case compatible
    case earlier
    case later
    case reject

type Weekday enum:
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday
    case sunday

--| The ISO 8601 week of a date. The year of the week differs from the year of the date around January 1.
type IsoWeek:
    year int
    week int

#[bind]
-fn real_ns_() -> int

#[bind]
-fn mono_ns_() -> int

-fn floor_div(a int, b int) -> int:
    q := a / b
    if a % b != 0 and (a < 0) != (b < 0):
        return q - 1
    return q

-fn floor_mod(a int, b int) -> int:
    return a - floor_div(a, b) * b

-fn abs_int(a int) -> int:
    if a < 0:
        return -a
    return a

-- Calendar.

--| Whether `year` has 366 days.
fn is_leap_year(year int) -> bool:
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)

--| Returns the number of days of `month` (1 to 12) in `year`.
fn days_in_month(year int, month int) -> int:
    switch month:
        case 1, 3, 5, 7, 8, 10, 12:
            return 31
        case 4, 6, 9, 11:
            return 30
        case 2:
            if is_leap_year(year):
                return 29
            return 28
        else:
            panic('A month is 1 to 12.')

-type Civil:
    y int
    m int
    d int

-- Days from 1970-01-01 to a civil date (Howard Hinnant, "chrono-Compatible Low-Level Date Algorithms").
-fn days_from_civil(y int, m int, d int) -> int:
    yy := y
    if m <= 2:
        yy -= 1
    era := floor_div(yy, 400)
    yoe := yy - era * 400
    mp := (m + 9) % 12
    doy := (153 * mp + 2) / 5 + d - 1
    doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468

-fn civil_from_days(days int) -> Civil:
    z := days + 719468
    era := floor_div(z, 146097)
    doe := z - era * 146097
    yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
    mp := (5 * doy + 2) / 153
    d := doy - (153 * mp + 2) / 5 + 1
    m := mp + 3
    if mp >= 10:
        m = mp - 9
    y := yoe + era * 400
    if m <= 2:
        y += 1
    return {y=y, m=m, d=d}

-- Monday is 0. 1970-01-01 was a Thursday.
-fn weekday_num(days int) -> int:
    return floor_mod(days + 3, 7)

-fn weekday_of(days int) -> Weekday:
    switch weekday_num(days):
        case 0:
            return .monday
        case 1:
            return .tuesday
        case 2:
            return .wednesday
        case 3:
            return .thursday
        case 4:
            return .friday
        case 5:
            return .saturday
        else:
            return .sunday

-fn year_day(days int) -> int:
    c := civil_from_days(days)
    return days - days_from_civil(c.y, 1, 1) + 1

-fn weeks_in_year(y int) -> int:
    wd := weekday_num(days_from_civil(y, 1, 1))
    if wd == 3 or (wd == 2 and is_leap_year(y)):
        return 53
    return 52

-fn iso_week_of(days int) -> IsoWeek:
    c := civil_from_days(days)
    doy := days - days_from_civil(c.y, 1, 1) + 1
    week := (doy - (weekday_num(days) + 1) + 10) / 7
    if week < 1:
        return {year=c.y - 1, week=weeks_in_year(c.y - 1)}
    if week == 53 and weeks_in_year(c.y) == 52:
        return {year=c.y + 1, week=1}
    return {year=c.y, week=week}

-fn valid_offset(off int) -> bool:
    return off >= MinOffset and off <= MaxOffset

-fn valid_instant(sec int) -> bool:
    return sec >= MinSec and sec <= MaxSec

-- Moves a civil date by months and keeps the day, or takes the last day of a shorter month.
-fn shift_months(days int, n int) -> !int:
    if n < -120000 or n > 120000:
        return error.Range
    c := civil_from_days(days)
    total := c.y * 12 + (c.m - 1) + n
    y := floor_div(total, 12)
    m := floor_mod(total, 12) + 1
    if y < 1 or y > 9999:
        return error.Range
    d := c.d
    last := days_in_month(y, m)
    if d > last:
        d = last
    return days_from_civil(y, m, d)

-fn shift_days(days int, n int) -> !int:
    if n < -4000000 or n > 4000000:
        return error.Range
    res := days + n
    if res < MinDay or res > MaxDay:
        return error.Range
    return res

-- Duration.

-fn dur(sec int, nsec int) -> Duration:
    -- The range is the same on both sides, -MaxDurSec to MaxDurSec seconds, so that `-d` is always in it.
    if sec < -MaxDurSec or sec > MaxDurSec or (sec == MaxDurSec and nsec > 0):
        panic('The duration is out of range.')
    return {sec=sec, nsec=nsec}

-fn dur_scaled(n int, unit int) -> Duration:
    if n < -(MaxDurSec / unit) or n > MaxDurSec / unit:
        panic('The duration is out of range.')
    return {sec=n * unit, nsec=0}

-fn dur_frac(n int, per_sec int) -> Duration:
    return dur(floor_div(n, per_sec), floor_mod(n, per_sec) * (NsPerSec / per_sec))

--| Returns a duration of `n` nanoseconds.
fn nanos(n int) -> Duration:
    return dur_frac(n, 1000000000)

fn micros(n int) -> Duration:
    return dur_frac(n, 1000000)

fn millis(n int) -> Duration:
    return dur_frac(n, 1000)

fn seconds(n int) -> Duration:
    return dur_scaled(n, 1)

fn minutes(n int) -> Duration:
    return dur_scaled(n, 60)

fn hours(n int) -> Duration:
    return dur_scaled(n, 3600)

--| Returns a duration of `n` times 24 hours.
fn days(n int) -> Duration:
    return dur_scaled(n, 86400)

--| Returns the whole seconds, rounded toward zero.
fn (&Duration) secs() -> int:
    if self.sec < 0 and self.nsec > 0:
        return self.sec + 1
    return self.sec

--| Returns the part below one second in nanoseconds. It has the sign of the duration.
fn (&Duration) subsec_nanos() -> int:
    if self.sec < 0 and self.nsec > 0:
        return self.nsec - NsPerSec
    return self.nsec

--| Returns the whole milliseconds, rounded toward zero.
fn (&Duration) millis() -> int:
    return self.secs() * 1000 + self.subsec_nanos() / 1000000

--| Returns the duration in seconds.
fn (&Duration) to_float() -> float:
    return float(self.sec) + float(self.nsec) / 1000000000.0

fn (&Duration) is_negative() -> bool:
    return self.sec < 0

fn (&Duration) abs() -> Duration:
    if self.sec < 0:
        return -self.*
    return self.*

fn (Duration) `-`() -> Duration:
    if self.nsec == 0:
        return dur(-self.sec, 0)
    return dur(-self.sec - 1, NsPerSec - self.nsec)

fn (&Duration) `+`(o Duration) -> Duration:
    sec := self.sec + o.sec
    nsec := self.nsec + o.nsec
    if nsec >= NsPerSec:
        sec += 1
        nsec -= NsPerSec
    return dur(sec, nsec)

fn (&Duration) `-`(o Duration) -> Duration:
    sec := self.sec - o.sec
    nsec := self.nsec - o.nsec
    if nsec < 0:
        sec -= 1
        nsec += NsPerSec
    return dur(sec, nsec)

fn (&Duration) `*`(n int) -> Duration:
    if n == 0:
        return {sec=0, nsec=0}
    -- `-n` of the least `int` is not an `int`. Half of it is, and doubling the half is exact.
    if n == -9223372036854775807 - 1:
        return (self.* * (n / 2)) * 2
    -- Multiply the sizes and set the sign at the end. A negative duration keeps `nsec` above `sec`, so its size
    -- is not `-sec`, and the range is the same on both sides, so the size is in range when the product is.
    a := self.abs()
    m := abs_int(n)
    if a.sec > 0 and m > MaxDurSec / a.sec:
        panic('The duration is out of range.')
    -- `nsec * m` can pass the range of `int`: multiply the billions of `m` apart. The sum stays below `m` when
    -- `a.sec` is 0, and below `MaxDurSec + m` with `m <= MaxDurSec` otherwise.
    q := m / NsPerSec
    low := a.nsec * (m % NsPerSec)
    res := dur(a.sec * m + a.nsec * q + low / NsPerSec, low % NsPerSec)
    if (self.sec < 0) != (n < 0):
        return -res
    return res

fn (&Duration) `<`(o Duration) -> bool:
    return self.sec < o.sec or (self.sec == o.sec and self.nsec < o.nsec)

fn (&Duration) `<=`(o Duration) -> bool:
    return self.sec < o.sec or (self.sec == o.sec and self.nsec <= o.nsec)

fn (&Duration) `>`(o Duration) -> bool:
    return self.sec > o.sec or (self.sec == o.sec and self.nsec > o.nsec)

fn (&Duration) `>=`(o Duration) -> bool:
    return self.sec > o.sec or (self.sec == o.sec and self.nsec >= o.nsec)

--| Returns the duration as hours, minutes and seconds, such as `1h2m3.5s`, `-1h30m` or `0s`.
fn (&Duration) format() -> str:
    a := self.abs()
    var buf []byte = {}
    if self.sec < 0:
        buf.append('-')
    h := a.sec / 3600
    m := a.sec % 3600 / 60
    s := a.sec % 60
    if h > 0:
        buf.append(str(h).span())
        buf.append('h')
    if m > 0:
        buf.append(str(m).span())
        buf.append('m')
    if s > 0 or a.nsec > 0 or (h == 0 and m == 0):
        buf.append(str(s).span())
        buf = put_frac(buf, a.nsec)
        buf.append('s')
    return str(buf)

-- Time.

--| Returns the current time of the system clock. The clock can be set, so it can go back:
--| measure elapsed time with `monotonic`.
fn now() -> Time:
    ns := real_ns_()
    sec := floor_div(ns, NsPerSec)
    if sec < MinSec:
        return {sec=MinSec, nsec=0}
    return {sec=sec, nsec=floor_mod(ns, NsPerSec)}

--| Returns the reading of a clock that never goes back. Only the difference of two readings has a meaning.
fn monotonic() -> Duration:
    ns := mono_ns_()
    return {sec=floor_div(ns, NsPerSec), nsec=floor_mod(ns, NsPerSec)}

--| Returns the instant `sec` seconds after 1970-01-01T00:00:00Z, or before it when `sec` is negative.
fn unix(sec int) -> !Time:
    return unix(sec, 0)

--| `nsec` can be any number of nanoseconds. It is added to `sec`.
fn unix(sec int, nsec int) -> !Time:
    if sec < MinSec - 10000000000 or sec > MaxSec + 10000000000:
        return error.Range
    s := sec + floor_div(nsec, NsPerSec)
    if !valid_instant(s):
        return error.Range
    return {sec=s, nsec=floor_mod(nsec, NsPerSec)}

fn unix_millis(ms int) -> !Time:
    s := floor_div(ms, 1000)
    if !valid_instant(s):
        return error.Range
    return {sec=s, nsec=floor_mod(ms, 1000) * 1000000}

--| Returns the seconds since 1970-01-01T00:00:00Z, rounded down.
fn (&Time) unix() -> int:
    return self.sec

--| Returns the milliseconds since 1970-01-01T00:00:00Z, rounded down.
fn (&Time) unix_millis() -> int:
    return self.sec * 1000 + self.nsec / 1000000

--| Returns the nanoseconds past the second, 0 to 999999999.
fn (&Time) subsec_nanos() -> int:
    return self.nsec

--| Returns the time moved by `d`, or `error.Range` when the result is out of range.
fn (&Time) add(d Duration) -> !Time:
    sec := self.sec + d.sec
    nsec := self.nsec + d.nsec
    if nsec >= NsPerSec:
        sec += 1
        nsec -= NsPerSec
    if !valid_instant(sec):
        return error.Range
    return {sec=sec, nsec=nsec}

fn (&Time) `+`(d Duration) -> Time:
    return self.add(d) !else:
        panic('The time is out of range.')

fn (&Time) `-`(d Duration) -> Time:
    return self.add(-d) !else:
        panic('The time is out of range.')

fn (&Time) `-`(o Time) -> Duration:
    sec := self.sec - o.sec
    nsec := self.nsec - o.nsec
    if nsec < 0:
        sec -= 1
        nsec += NsPerSec
    return {sec=sec, nsec=nsec}

fn (&Time) `<`(o Time) -> bool:
    return self.sec < o.sec or (self.sec == o.sec and self.nsec < o.nsec)

fn (&Time) `<=`(o Time) -> bool:
    return self.sec < o.sec or (self.sec == o.sec and self.nsec <= o.nsec)

fn (&Time) `>`(o Time) -> bool:
    return self.sec > o.sec or (self.sec == o.sec and self.nsec > o.nsec)

fn (&Time) `>=`(o Time) -> bool:
    return self.sec > o.sec or (self.sec == o.sec and self.nsec >= o.nsec)

--| Returns the date and time of day in UTC.
fn (&Time) utc() -> DateTime:
    return {sec=self.sec, nsec=self.nsec, off=0}

--| Returns the date and time of day at `offset` minutes east of UTC: 540 is +09:00, -210 is -03:30.
fn (&Time) to_offset(offset int) -> !DateTime:
    if !valid_offset(offset):
        return error.Range
    return {sec=self.sec, nsec=self.nsec, off=offset}

--| Returns the date and time of day in a time zone.
fn (&Time) to_zone(zone Zone) -> DateTime:
    return in_zone(self.sec, self.nsec, zone)

--| Returns the time as RFC 3339 in UTC, such as `2026-11-15T01:22:03.5Z`.
fn (&Time) format() -> str:
    return self.utc().format()

--| Returns the time in UTC in a `strftime` format. See `DateTime.format`.
fn (&Time) format(fmt str) -> !str:
    return self.utc().format(fmt)

-- DateTime.

-fn make_datetime(day int, hour int, minute int, second int, nsec int, offset int) -> !DateTime:
    if hour < 0 or hour > 23 or minute < 0 or minute > 59 or second < 0 or second > 59:
        return error.Range
    if nsec < 0 or nsec >= NsPerSec or !valid_offset(offset):
        return error.Range
    sec := day * SecsPerDay + hour * 3600 + minute * 60 + second - offset * 60
    if !valid_instant(sec):
        return error.Range
    return {sec=sec, nsec=nsec, off=offset}

--| Returns a date and time of day in UTC. `error.Range` when a field is out of range or the day does not exist.
fn datetime(year int, month int, day int, hour int, minute int, second int) -> !DateTime:
    return datetime(year, month, day, hour, minute, second, 0, 0)

--| Returns a date and time of day at `offset` minutes east of UTC.
fn datetime(year int, month int, day int, hour int, minute int, second int, nsec int, offset int) -> !DateTime:
    d := date(year, month, day)!
    return make_datetime(d.days, hour, minute, second, nsec, offset)

-fn (&DateTime) local_sec() -> int:
    return self.sec + self.off * 60

-fn (&DateTime) local_day() -> int:
    return floor_div(self.local_sec(), SecsPerDay)

-fn (&DateTime) day_sec() -> int:
    return floor_mod(self.local_sec(), SecsPerDay)

fn (&DateTime) year() -> int:
    return civil_from_days(self.local_day()).y

--| Returns the month, 1 to 12.
fn (&DateTime) month() -> int:
    return civil_from_days(self.local_day()).m

--| Returns the day of the month, 1 to 31.
fn (&DateTime) day() -> int:
    return civil_from_days(self.local_day()).d

fn (&DateTime) hour() -> int:
    return self.day_sec() / 3600

fn (&DateTime) minute() -> int:
    return self.day_sec() % 3600 / 60

fn (&DateTime) second() -> int:
    return self.day_sec() % 60

fn (&DateTime) nanosecond() -> int:
    return self.nsec

--| Returns the UTC offset in minutes east of UTC.
fn (&DateTime) offset() -> int:
    return self.off

fn (&DateTime) weekday() -> Weekday:
    return weekday_of(self.local_day())

--| Returns the day of the year, 1 to 366.
fn (&DateTime) day_of_year() -> int:
    return year_day(self.local_day())

--| Returns the calendar day at the offset of this value.
fn (&DateTime) date() -> Date:
    return {days=self.local_day()}

--| Returns the instant.
fn (&DateTime) time() -> Time:
    return {sec=self.sec, nsec=self.nsec}

--| Returns the same instant in UTC.
fn (&DateTime) utc() -> DateTime:
    return {sec=self.sec, nsec=self.nsec, off=0}

--| Returns the same instant at another offset: the date and the time of day change.
fn (&DateTime) to_offset(offset int) -> !DateTime:
    if !valid_offset(offset):
        return error.Range
    return {sec=self.sec, nsec=self.nsec, off=offset}

--| Returns the same date and time of day at another offset: the instant changes.
fn (&DateTime) replace_offset(offset int) -> !DateTime:
    return make_datetime(self.local_day(), self.hour(), self.minute(), self.second(), self.nsec, offset)

--| Returns the time zone of a value that `to_zone` or a `Zone` made, or `none` for one at a fixed offset.
fn (&DateTime) zone() -> ?Zone:
    if self.tz.kind == 0:
        return none
    return self.tz

--| Returns the same instant in a time zone: the date and the time of day change.
fn (&DateTime) to_zone(zone Zone) -> DateTime:
    return in_zone(self.sec, self.nsec, zone)

--| Returns the same date and time of day in a time zone: the instant changes. A time that the zone has
--| twice or not at all is read as `Disambiguation.compatible` says.
fn (&DateTime) replace_zone(zone Zone) -> !DateTime:
    return zone.at_local(self.local_sec(), self.nsec, .compatible)

--| Returns the value moved by `d`, or `error.Range` when the result is out of range.
--| In a time zone the offset is that of the new instant: one hour after 01:30 can be 03:30.
fn (&DateTime) add(d Duration) -> !DateTime:
    t := self.time().add(d)!
    if self.tz.kind != 0:
        return in_zone(t.sec, t.nsec, self.tz)
    return {sec=t.sec, nsec=t.nsec, off=self.off}

fn (&DateTime) `+`(d Duration) -> DateTime:
    return self.add(d) !else:
        panic('The time is out of range.')

fn (&DateTime) `-`(d Duration) -> DateTime:
    return self.add(-d) !else:
        panic('The time is out of range.')

--| Returns the time from `o` to this value. The offsets and the zones do not count: it is `self.time() - o.time()`.
fn (&DateTime) `-`(o DateTime) -> Duration:
    return self.time() - o.time()

--| Whether this instant comes before that of `o`. The offsets and the zones do not count.
fn (&DateTime) `<`(o DateTime) -> bool:
    return self.sec < o.sec or (self.sec == o.sec and self.nsec < o.nsec)

fn (&DateTime) `<=`(o DateTime) -> bool:
    return self.sec < o.sec or (self.sec == o.sec and self.nsec <= o.nsec)

fn (&DateTime) `>`(o DateTime) -> bool:
    return self.sec > o.sec or (self.sec == o.sec and self.nsec > o.nsec)

fn (&DateTime) `>=`(o DateTime) -> bool:
    return self.sec > o.sec or (self.sec == o.sec and self.nsec >= o.nsec)

-fn (&DateTime) on_day(day int) -> !DateTime:
    if self.tz.kind != 0:
        return self.tz.at_local(day * SecsPerDay + self.day_sec(), self.nsec, .compatible)
    sec := day * SecsPerDay + self.day_sec() - self.off * 60
    if !valid_instant(sec):
        return error.Range
    return {sec=sec, nsec=self.nsec, off=self.off}

--| Returns the value `n` days later, or earlier when `n` is negative. The time of day stays.
--| In a time zone a day can be 23 or 25 hours, and a time of day that the new day does not have, or has twice,
--| is read as `Disambiguation.compatible` says.
fn (&DateTime) add_days(n int) -> !DateTime:
    return self.on_day(shift_days(self.local_day(), n)!)

--| Returns the value `n` months later. The day stays, or becomes the last day of a shorter month:
--| January 31 plus one month is February 28 or 29.
fn (&DateTime) add_months(n int) -> !DateTime:
    return self.on_day(shift_months(self.local_day(), n)!)

--| Returns the value `n` years later. February 29 becomes February 28 in a year that is not a leap year.
fn (&DateTime) add_years(n int) -> !DateTime:
    if n < -10000 or n > 10000:
        return error.Range
    return self.on_day(shift_months(self.local_day(), n * 12)!)

--| Returns the value as RFC 3339, such as `2026-11-15T10:22:03.25+09:00`. UTC is written `Z`.
--| The fraction of the second is left out when it is zero.
fn (&DateTime) format() -> str:
    var buf []byte = {}
    c := civil_from_days(self.local_day())
    sod := self.day_sec()
    buf = put_num(buf, c.y, 4)
    buf.append('-')
    buf = put_num(buf, c.m, 2)
    buf.append('-')
    buf = put_num(buf, c.d, 2)
    buf.append('T')
    buf = put_num(buf, sod / 3600, 2)
    buf.append(':')
    buf = put_num(buf, sod % 3600 / 60, 2)
    buf.append(':')
    buf = put_num(buf, sod % 60, 2)
    buf = put_frac(buf, self.nsec)
    if self.off == 0:
        buf.append('Z')
    else:
        buf = put_offset(buf, self.off, true)
    return str(buf)

--| Returns the value in a `strftime` format.
--| Date: `%Y %y %m %d %e %j %b %h %B %a %A %u %w %G %V %U %W`. `%U` and `%W` are the week of the year, 00 to 53,
--| with weeks that start on Sunday and on Monday: the days before the first Sunday or Monday are in week 00.
--| Time of day: `%H %I %p %M %S %f %3f %6f %9f`.
--| Offset: `%z` (`+0900`), `%:z` (`+09:00`), `%Z` (the abbreviation of the zone such as `KST`, or `UTC`, or
--| the offset when the value has no zone). Others: `%F` (`%Y-%m-%d`), `%T` (`%H:%M:%S`), `%R` (`%H:%M`),
--| `%D` (`%m/%d/%y`), `%s` (Unix seconds), `%n`, `%t`, `%%`. Names are in English.
--| `error.Format` for another specifier.
fn (&DateTime) format(fmt str) -> !str:
    abbr := ''
    if has_zone_spec(fmt):
        -- The abbreviation is found only for `%Z`.
        abbr = self.abbr()
    f := Formatter{day=self.local_day(), sod=self.day_sec(), nsec=self.nsec, off=self.off, unix=self.sec, date_only=false, abbr=abbr}
    return str(f.run({}, fmt)!)

-fn (&DateTime) abbr() -> str:
    if self.tz.kind != 0:
        return self.tz.info_at(self.sec).abbr
    if self.off == 0:
        return 'UTC'
    return str(put_offset({}, self.off, true))

-- Whether a format has `%Z`. `%%` is a percent sign, and the letter after it is not a specifier.
-fn has_zone_spec(fmt str) -> bool:
    i := 0
    n := fmt.len()
    while i + 1 < n:
        if fmt[i] == '%':
            if fmt[i + 1] == 'Z':
                return true
            i += 2
            continue
        i += 1
    return false

-- Date.

--| Returns a calendar day. `error.Range` when the day does not exist, such as February 30.
fn date(year int, month int, day int) -> !Date:
    if year < 1 or year > 9999 or month < 1 or month > 12:
        return error.Range
    if day < 1 or day > days_in_month(year, month):
        return error.Range
    return {days=days_from_civil(year, month, day)}

fn (&Date) year() -> int:
    return civil_from_days(self.days).y

--| Returns the month, 1 to 12.
fn (&Date) month() -> int:
    return civil_from_days(self.days).m

--| Returns the day of the month, 1 to 31.
fn (&Date) day() -> int:
    return civil_from_days(self.days).d

fn (&Date) weekday() -> Weekday:
    return weekday_of(self.days)

--| Returns the day of the week as a number: Monday is 1, Sunday is 7.
fn (&Date) iso_weekday() -> int:
    return weekday_num(self.days) + 1

--| Returns the day of the year, 1 to 366.
fn (&Date) day_of_year() -> int:
    return year_day(self.days)

--| Returns the ISO 8601 week: weeks start on Monday, and week 1 is the week of the first Thursday of the year.
fn (&Date) iso_week() -> IsoWeek:
    return iso_week_of(self.days)

fn (&Date) add_days(n int) -> !Date:
    return {days=shift_days(self.days, n)!}

--| Returns the date `n` months later. The day stays, or becomes the last day of a shorter month.
fn (&Date) add_months(n int) -> !Date:
    return {days=shift_months(self.days, n)!}

fn (&Date) add_years(n int) -> !Date:
    if n < -10000 or n > 10000:
        return error.Range
    return {days=shift_months(self.days, n * 12)!}

--| Returns the number of days from `o` to this date.
fn (&Date) `-`(o Date) -> int:
    return self.days - o.days

fn (&Date) `<`(o Date) -> bool:
    return self.days < o.days

fn (&Date) `<=`(o Date) -> bool:
    return self.days <= o.days

fn (&Date) `>`(o Date) -> bool:
    return self.days > o.days

fn (&Date) `>=`(o Date) -> bool:
    return self.days >= o.days

--| Returns this day at a time of day in UTC.
fn (&Date) at(hour int, minute int, second int) -> !DateTime:
    return make_datetime(self.days, hour, minute, second, 0, 0)

--| Returns this day at a time of day in a time zone. See `Zone.datetime`.
fn (&Date) at(hour int, minute int, second int, zone Zone) -> !DateTime:
    if hour < 0 or hour > 23 or minute < 0 or minute > 59 or second < 0 or second > 59:
        return error.Range
    return zone.at_local(self.days * SecsPerDay + hour * 3600 + minute * 60 + second, 0, .compatible)

--| Returns this day at a time of day at `offset` minutes east of UTC.
fn (&Date) at(hour int, minute int, second int, nsec int, offset int) -> !DateTime:
    return make_datetime(self.days, hour, minute, second, nsec, offset)

--| Returns the date as `2026-11-15`.
fn (&Date) format() -> str:
    var buf []byte = {}
    c := civil_from_days(self.days)
    buf = put_num(buf, c.y, 4)
    buf.append('-')
    buf = put_num(buf, c.m, 2)
    buf.append('-')
    buf = put_num(buf, c.d, 2)
    return str(buf)

--| Returns the date in a `strftime` format. See `DateTime.format`. A specifier of the time of day or
--| of the offset is `error.Format`.
fn (&Date) format(fmt str) -> !str:
    f := Formatter{day=self.days, sod=0, nsec=0, off=0, unix=0, date_only=true, abbr=''}
    return str(f.run({}, fmt)!)

-- Formatting.

-fn put_num(buf []byte, v int, width int) -> []byte:
    s := str(v)
    var b []byte = buf
    for 0..(width - s.len()) |i|:
        b.append('0')
    b.append(s.span())
    return b

-- Appends `.` and the digits of `nsec` without trailing zeros, or nothing for 0.
-fn put_frac(buf []byte, nsec int) -> []byte:
    if nsec == 0:
        return buf
    digits := 9
    v := nsec
    while v % 10 == 0:
        v /= 10
        digits -= 1
    var b []byte = buf
    b.append('.')
    return put_num(b, v, digits)

-fn put_offset(buf []byte, off int, colon bool) -> []byte:
    var b []byte = buf
    a := off
    if off < 0:
        b.append('-')
        a = -off
    else:
        b.append('+')
    b = put_num(b, a / 60, 2)
    if colon:
        b.append(':')
    return put_num(b, a % 60, 2)

-fn month_name(m int) -> str:
    switch m:
        case 1:
            return 'January'
        case 2:
            return 'February'
        case 3:
            return 'March'
        case 4:
            return 'April'
        case 5:
            return 'May'
        case 6:
            return 'June'
        case 7:
            return 'July'
        case 8:
            return 'August'
        case 9:
            return 'September'
        case 10:
            return 'October'
        case 11:
            return 'November'
        else:
            return 'December'

-- `wd` is 0 for Monday.
-fn weekday_name(wd int) -> str:
    switch wd:
        case 0:
            return 'Monday'
        case 1:
            return 'Tuesday'
        case 2:
            return 'Wednesday'
        case 3:
            return 'Thursday'
        case 4:
            return 'Friday'
        case 5:
            return 'Saturday'
        else:
            return 'Sunday'

-type Formatter:
    day       int
    sod       int
    nsec      int
    off       int
    unix      int
    date_only bool
    abbr      str

-fn (&Formatter) run(out []byte, fmt str) -> ![]byte:
    var buf []byte = out
    c := civil_from_days(self.day)
    i := 0
    n := fmt.len()
    while i < n:
        ch := fmt[i]
        i += 1
        if ch != '%':
            buf.append(ch)
            continue
        if i >= n:
            return error.Format
        f := fmt[i]
        i += 1
        colon := false
        width := 0
        if f == ':':
            if i >= n or fmt[i] != 'z':
                return error.Format
            colon = true
            f = 'z'
            i += 1
        else f == '3' or f == '6' or f == '9':
            if i >= n or fmt[i] != 'f':
                return error.Format
            width = int(f) - 48
            f = 'f'
            i += 1
        if self.date_only:
            switch f:
                case 'H', 'I', 'p', 'M', 'S', 'f', 'z', 'Z', 'T', 'R', 's':
                    return error.Format
                else:
                    pass
        switch f:
            case 'Y':
                buf = put_num(buf, c.y, 4)
            case 'y':
                buf = put_num(buf, c.y % 100, 2)
            case 'm':
                buf = put_num(buf, c.m, 2)
            case 'd':
                buf = put_num(buf, c.d, 2)
            case 'e':
                if c.d < 10:
                    buf.append(' ')
                buf.append(str(c.d).span())
            case 'j':
                buf = put_num(buf, year_day(self.day), 3)
            case 'b', 'h':
                buf.append(month_name(c.m)[0..3].span())
            case 'B':
                buf.append(month_name(c.m).span())
            case 'a':
                buf.append(weekday_name(weekday_num(self.day))[0..3].span())
            case 'A':
                buf.append(weekday_name(weekday_num(self.day)).span())
            case 'u':
                buf = put_num(buf, weekday_num(self.day) + 1, 1)
            case 'w':
                buf = put_num(buf, (weekday_num(self.day) + 1) % 7, 1)
            case 'G':
                buf = put_num(buf, iso_week_of(self.day).year, 4)
            case 'V':
                buf = put_num(buf, iso_week_of(self.day).week, 2)
            case 'U':
                -- The week that starts on Sunday: Sunday is 0 here.
                buf = put_num(buf, (year_day(self.day) + 6 - (weekday_num(self.day) + 1) % 7) / 7, 2)
            case 'W':
                buf = put_num(buf, (year_day(self.day) + 6 - weekday_num(self.day)) / 7, 2)
            case 'H':
                buf = put_num(buf, self.sod / 3600, 2)
            case 'I':
                h := self.sod / 3600 % 12
                if h == 0:
                    h = 12
                buf = put_num(buf, h, 2)
            case 'p':
                if self.sod < 43200:
                    buf.append('AM'.span())
                else:
                    buf.append('PM'.span())
            case 'M':
                buf = put_num(buf, self.sod % 3600 / 60, 2)
            case 'S':
                buf = put_num(buf, self.sod % 60, 2)
            case 'f':
                switch width:
                    case 3:
                        buf = put_num(buf, self.nsec / 1000000, 3)
                    case 9:
                        buf = put_num(buf, self.nsec, 9)
                    else:
                        buf = put_num(buf, self.nsec / 1000, 6)
            case 'z':
                buf = put_offset(buf, self.off, colon)
            case 'Z':
                buf.append(self.abbr.span())
            case 's':
                buf.append(str(self.unix).span())
            case 'F':
                buf = self.run(buf, '%Y-%m-%d')!
            case 'T':
                buf = self.run(buf, '%H:%M:%S')!
            case 'R':
                buf = self.run(buf, '%H:%M')!
            case 'D':
                buf = self.run(buf, '%m/%d/%y')!
            case 'n':
                buf.append('\n')
            case 't':
                buf.append('\t')
            case '%':
                buf.append('%')
            else:
                return error.Format
    return buf

-- Parsing.

-type Parts:
    year    int = 1970
    month   int = 1
    day     int = 1
    hour    int = 0
    minute  int = 0
    second  int = 0
    nsec    int = 0
    off     int = 0
    has_off bool = false
    -- 0 for AM, 1 for PM, -1 when the text has neither.
    pm      int = -1
    unix    int = 0
    has_unix bool = false
    -- The day of the year of `%j`, 0 when the format has none, and whether the format has a month or a day.
    yday    int = 0
    has_md  bool = false

-type Scan:
    src     str
    pos     int = 0
    msg     str = ''
    err_pos int = 0

-fn (&Scan) at_end() -> bool:
    return self.pos >= self.src.len()

-- The byte at the position, or 0 at the end.
-fn (&Scan) peek() -> byte:
    if self.pos >= self.src.len():
        return 0
    return self.src[self.pos]

-fn (&Scan) found() -> str:
    if self.pos >= self.src.len():
        return 'the end of the text'
    end := self.pos + 1
    while end < self.src.len() and (int(self.src[end]) && 0xc0) == 0x80:
        end += 1
    return '`' + self.src[self.pos..end] + '`'

-fn (&&Scan) fail(pos int, msg str):
    self.msg = msg
    self.err_pos = pos

-fn (&&Scan) expected(what str) -> error:
    self.fail(self.pos, 'Expected ' + what + ', found ' + self.found() + '.')
    return error.Syntax

-- Reads `min` to `max` digits.
-fn (&&Scan) digits(min int, max int, what str) -> !int:
    start := self.pos
    v := 0
    while self.pos < self.src.len() and self.pos - start < max:
        c := self.src[self.pos]
        if !str.is_ascii_digit(c):
            break
        v = v * 10 + int(c - '0')
        self.pos += 1
    if self.pos - start < min:
        return self.expected(what)
    return v

-fn (&&Scan) literal(c byte, what str) -> !void:
    if self.peek() != c or self.at_end():
        return self.expected(what)
    self.pos += 1

-- Reads the digits of a fraction of a second. Digits past the ninth are dropped.
-fn (&&Scan) fraction() -> !int:
    start := self.pos
    v := 0
    while self.pos < self.src.len():
        c := self.src[self.pos]
        if !str.is_ascii_digit(c):
            break
        if self.pos - start < 9:
            v = v * 10 + int(c - '0')
        self.pos += 1
    count := self.pos - start
    if count == 0:
        return self.expected('the digits of a fraction of a second')
    while count < 9:
        v *= 10
        count += 1
    return v

-- Reads `Z`, `+09:00`, `+0900` or `+09`.
-fn (&&Scan) offset() -> !int:
    start := self.pos
    c := self.peek()
    if !self.at_end() and (c == 'Z' or c == 'z'):
        self.pos += 1
        return 0
    if self.at_end() or (c != '+' and c != '-'):
        return self.expected('a UTC offset such as `Z` or `+09:00`')
    self.pos += 1
    h := self.digits(2, 2, 'the two digits of the offset hours')!
    m := 0
    if !self.at_end() and self.peek() == ':':
        self.pos += 1
        m = self.digits(2, 2, 'the two digits of the offset minutes')!
    else !self.at_end() and str.is_ascii_digit(self.peek()):
        m = self.digits(2, 2, 'the two digits of the offset minutes')!
    if h > 23 or m > 59:
        self.fail(start, 'A UTC offset is at most 23:59.')
        return error.Range
    if c == '-':
        return -(h * 60 + m)
    return h * 60 + m

-fn is_space(c byte) -> bool:
    return c == ' ' or c == '\t' or c == '\n' or c == '\r'

-- Whether `src` has `word` at `pos`, ignoring ASCII case.
-fn has_word(src str, pos int, word str) -> bool:
    if pos + word.len() > src.len():
        return false
    for 0..word.len() |i|:
        if str.ascii_lower(src[pos + i]) != str.ascii_lower(word[i]):
            return false
    return true

-- Reads a full or a three letter month name and returns the month.
-fn (&&Scan) month() -> !int:
    for 1..13 |m|:
        name := month_name(m)
        if has_word(self.src, self.pos, name):
            self.pos += name.len()
            return m
    for 1..13 |m|:
        if has_word(self.src, self.pos, month_name(m)[0..3]):
            self.pos += 3
            return m
    return self.expected('the name of a month such as `Nov` or `November`')

-fn (&&Scan) weekday() -> !void:
    for 0..7 |wd|:
        name := weekday_name(wd)
        if has_word(self.src, self.pos, name):
            self.pos += name.len()
            return
    for 0..7 |wd|:
        if has_word(self.src, self.pos, weekday_name(wd)[0..3]):
            self.pos += 3
            return
    return self.expected('the name of a day such as `Sun` or `Sunday`')

-- Checks the fields and makes the value. `default_off` is the offset of a text that has none.
-fn (&&Scan) finish(p &Parts, default_off int) -> !DateTime:
    off := default_off
    if p.has_off:
        off = p.off
    if p.has_unix:
        if !valid_instant(p.unix):
            self.fail(0, 'The time is out of range: years 1 to 9999.')
            return error.Range
        return {sec=p.unix, nsec=p.nsec, off=off}
    if p.month < 1 or p.month > 12:
        self.fail(0, 'A month is 1 to 12, found ' + str(p.month) + '.')
        return error.Range
    if p.year < 1 or p.year > 9999:
        self.fail(0, 'A year is 1 to 9999, found ' + str(p.year) + '.')
        return error.Range
    if p.day < 1 or p.day > days_in_month(p.year, p.month):
        self.fail(0, month_name(p.month) + ' ' + str(p.year) + ' has no day ' + str(p.day) + '.')
        return error.Range
    hour := p.hour
    if p.pm >= 0:
        if hour < 1 or hour > 12:
            self.fail(0, 'An hour with AM or PM is 1 to 12, found ' + str(hour) + '.')
            return error.Range
        hour = hour % 12 + p.pm * 12
    if hour > 23:
        self.fail(0, 'An hour is 0 to 23, found ' + str(hour) + '.')
        return error.Range
    if p.minute > 59:
        self.fail(0, 'A minute is 0 to 59, found ' + str(p.minute) + '.')
        return error.Range
    second := p.second
    if second == 60:
        -- A leap second. The clock of this module has none: it reads as the second before.
        second = 59
    if second > 59:
        self.fail(0, 'A second is 0 to 59, found ' + str(second) + '.')
        return error.Range
    return make_datetime(days_from_civil(p.year, p.month, p.day), hour, p.minute, second, p.nsec, off) !else |err|:
        self.fail(0, 'The time is out of range: years 1 to 9999.')
        return err

-fn (&&Scan) date_part(p &Parts) -> !void:
    p.year = self.digits(4, 4, 'a four digit year')!
    self.literal('-', '`-` after the year')!
    p.month = self.digits(2, 2, 'a two digit month')!
    self.literal('-', '`-` after the month')!
    p.day = self.digits(2, 2, 'a two digit day')!

-fn (&&Scan) rfc3339(default_off int) -> !DateTime:
    var p Parts = {}
    self.clock_part(&p)!
    if self.at_end():
        if default_off == NoOffset:
            self.fail(self.pos, 'The text has no UTC offset such as `Z` or `+09:00`. To read it at an offset, pass the offset in minutes: `time.parse(s, 0)` reads it as UTC.')
            return error.Syntax
    else:
        if self.peek() == '[':
            self.fail(self.pos, 'A time zone in brackets is read by `time.parse_zoned`.')
            return error.Syntax
        p.off = self.offset()!
        p.has_off = true
        if !self.at_end():
            if self.peek() == '[':
                self.fail(self.pos, 'A time zone in brackets is read by `time.parse_zoned`.')
                return error.Syntax
            return self.expected('the end of the text after the UTC offset')
    return self.finish(&p, default_off)

-- Reads the date, the separator and the time of day of an RFC 3339 timestamp.
-fn (&&Scan) clock_part(p &Parts) -> !void:
    self.date_part(p)!
    sep := self.peek()
    if self.at_end() or (sep != 'T' and sep != 't' and sep != ' '):
        return self.expected('`T` or a space between the date and the time of day')
    self.pos += 1
    p.hour = self.digits(2, 2, 'a two digit hour')!
    self.literal(':', '`:` after the hour')!
    p.minute = self.digits(2, 2, 'a two digit minute')!
    self.literal(':', '`:` after the minute')!
    p.second = self.digits(2, 2, 'a two digit second')!
    c := self.peek()
    if !self.at_end() and (c == '.' or c == ','):
        self.pos += 1
        p.nsec = self.fraction()!

-- Reads the text by a `strptime` format.
-fn (&&Scan) by_format(fmt str, p &Parts) -> !void:
    i := 0
    n := fmt.len()
    while i < n:
        ch := fmt[i]
        i += 1
        if is_space(ch):
            if self.at_end() or !is_space(self.peek()):
                return self.expected('a space')
            while !self.at_end() and is_space(self.peek()):
                self.pos += 1
            continue
        if ch != '%':
            if self.at_end() or self.peek() != ch:
                return self.expected('`' + fmt[i - 1..i] + '`')
            self.pos += 1
            continue
        if i >= n:
            self.fail(i - 1, 'The format ends with a single `%`. Write `%%` for a percent sign.')
            return error.Format
        f := fmt[i]
        i += 1
        if f == ':' or f == '3' or f == '6' or f == '9':
            want := byte('f')
            if f == ':':
                want = 'z'
            if i >= n or fmt[i] != want:
                self.fail(i - 2, 'Unknown specifier `%' + fmt[i - 1..i] + '`. The ones with a prefix are `%:z`, `%3f`, `%6f` and `%9f`.')
                return error.Format
            f = want
            i += 1
        switch f:
            case 'Y':
                p.year = self.digits(4, 4, 'a four digit year')!
            case 'y':
                y := self.digits(2, 2, 'a two digit year')!
                if y >= 69:
                    p.year = 1900 + y
                else:
                    p.year = 2000 + y
            case 'm':
                p.month = self.digits(1, 2, 'a month')!
                p.has_md = true
            case 'd':
                p.day = self.digits(1, 2, 'a day of the month')!
                p.has_md = true
            case 'e':
                while !self.at_end() and self.peek() == ' ':
                    self.pos += 1
                p.day = self.digits(1, 2, 'a day of the month')!
                p.has_md = true
            case 'j':
                start := self.pos
                doy := self.digits(1, 3, 'a day of the year')!
                if doy < 1 or doy > 366:
                    self.fail(start, 'A day of the year is 1 to 366.')
                    return error.Range
                -- The year can come later in the format: the month and the day are found at the end.
                p.yday = doy
            case 'b', 'h', 'B':
                p.month = self.month()!
                p.has_md = true
            case 'a', 'A':
                self.weekday()!
            case 'H', 'I':
                p.hour = self.digits(1, 2, 'an hour')!
            case 'p':
                if has_word(self.src, self.pos, 'AM'):
                    p.pm = 0
                else has_word(self.src, self.pos, 'PM'):
                    p.pm = 1
                else:
                    return self.expected('`AM` or `PM`')
                self.pos += 2
            case 'M':
                p.minute = self.digits(1, 2, 'a minute')!
            case 'S':
                p.second = self.digits(1, 2, 'a second')!
            case 'f':
                p.nsec = self.fraction()!
            case 'z':
                p.off = self.offset()!
                p.has_off = true
            case 's':
                neg := false
                if !self.at_end() and self.peek() == '-':
                    neg = true
                    self.pos += 1
                v := self.digits(1, 12, 'Unix seconds')!
                if neg:
                    v = -v
                p.unix = v
                p.has_unix = true
            case 'F':
                self.by_format('%Y-%m-%d', p)!
            case 'T':
                self.by_format('%H:%M:%S', p)!
            case 'R':
                self.by_format('%H:%M', p)!
            case 'D':
                self.by_format('%m/%d/%y', p)!
            case 'n', 't':
                if self.at_end() or !is_space(self.peek()):
                    return self.expected('a space')
                while !self.at_end() and is_space(self.peek()):
                    self.pos += 1
            case '%':
                self.literal('%', '`%`')!
            case 'u', 'w', 'G', 'V', 'U', 'W':
                self.fail(i - 2, '`%' + fmt[i - 1..i] + '` is for output only. Parse the date with `%Y`, `%m` and `%d`, or with `%j`.')
                return error.Format
            case 'Z':
                self.fail(i - 2, '`%Z` is for output only: an abbreviation such as `CST` names more than one zone. Parse the offset with `%z`, or read the text in a zone with `replace_zone`.')
                return error.Format
            else:
                self.fail(i - 2, 'Unknown specifier `%' + fmt[i - 1..i] + '`. See `DateTime.format` for the list.')
                return error.Format

-fn (&&Scan) formatted(fmt str, default_off int) -> !DateTime:
    var p Parts = {}
    self.by_format(fmt, &p)!
    if !self.at_end():
        return self.expected('the end of the text after the format')
    if p.yday > 0:
        -- `%j`: turn the day of the year into a month and a day.
        if p.has_md:
            self.fail(0, '`%j` gives the month and the day: the format can not also have `%m`, `%d`, `%e` or `%b`.')
            return error.Format
        if p.year < 1 or p.year > 9999:
            self.fail(0, 'A year is 1 to 9999, found ' + str(p.year) + '.')
            return error.Range
        if p.yday == 366 and !is_leap_year(p.year):
            self.fail(0, str(p.year) + ' has no day 366.')
            return error.Range
        c := civil_from_days(days_from_civil(p.year, 1, 1) + p.yday - 1)
        p.month = c.m
        p.day = c.d
    return self.finish(&p, default_off)

-fn report(s &Scan, diag &&Diag):
    diag.msg = s.msg
    diag.pos = s.err_pos

--| Parses an RFC 3339 timestamp such as `2026-11-15T10:22:03.5+09:00`. The text must have a UTC offset.
--| A space can stand for the `T`, `,` for the `.`, and the offset can be `Z`, `+09:00`, `+0900` or `+09`.
--| `error.Syntax` when the text has another shape, `error.Range` when a field is out of range.
fn parse(s str) -> !DateTime:
    var diag Diag = {}
    return parse(s, &&diag)

--| On failure, `diag` tells where and why.
fn parse(s str, diag &&Diag) -> !DateTime:
    return parse_at(s, NoOffset, diag)

--| Parses a timestamp that can be without a UTC offset, such as `2026-11-15 10:22:03`: it is read at `offset`
--| minutes east of UTC. An offset in the text wins.
fn parse(s str, offset int) -> !DateTime:
    var diag Diag = {}
    return parse(s, offset, &&diag)

fn parse(s str, offset int, diag &&Diag) -> !DateTime:
    diag.msg = ''
    diag.pos = 0
    if !valid_offset(offset):
        diag.msg = 'A UTC offset is -1439 to 1439 minutes.'
        return error.Range
    return parse_at(s, offset, diag)

-fn parse_at(s str, offset int, diag &&Diag) -> !DateTime:
    diag.msg = ''
    diag.pos = 0
    sc := Scan{src=s}
    return sc.rfc3339(offset) !else |err|:
        report(&sc, diag)
        return err

--| Parses `s` by a `strptime` format, such as `%d/%b/%Y:%H:%M:%S %z`. The specifiers are those of
--| `DateTime.format` without `%u %w %G %V %U %W`. A number takes one or two digits (`%Y` four, `%f` one to nine),
--| a space in the format takes one or more, `%b` and `%a` take the short or the full name in any case, and
--| `%z` takes `Z`, `+0900`, `+09:00` or `+09`. A field that the format does not have is that of
--| 1970-01-01T00:00:00, and without `%z` the text is read as UTC.
--| `error.Syntax` when the text does not fit, `error.Range` for a field out of range and `error.Format`
--| for a specifier that is not known.
fn parse_format(s str, fmt str) -> !DateTime:
    var diag Diag = {}
    return parse_format(s, fmt, 0, &&diag)

fn parse_format(s str, fmt str, diag &&Diag) -> !DateTime:
    return parse_format(s, fmt, 0, diag)

--| A text without `%z` is read at `offset` minutes east of UTC.
fn parse_format(s str, fmt str, offset int) -> !DateTime:
    var diag Diag = {}
    return parse_format(s, fmt, offset, &&diag)

fn parse_format(s str, fmt str, offset int, diag &&Diag) -> !DateTime:
    diag.msg = ''
    diag.pos = 0
    if !valid_offset(offset):
        diag.msg = 'A UTC offset is -1439 to 1439 minutes.'
        return error.Range
    sc := Scan{src=s}
    return sc.formatted(fmt, offset) !else |err|:
        report(&sc, diag)
        return err

--| Parses a date such as `2026-11-15`.
fn parse_date(s str) -> !Date:
    var diag Diag = {}
    return parse_date(s, &&diag)

fn parse_date(s str, diag &&Diag) -> !Date:
    diag.msg = ''
    diag.pos = 0
    sc := Scan{src=s}
    var p Parts = {}
    sc.date_part(&p) !else |err|:
        report(&sc, diag)
        return err
    if !sc.at_end():
        err := sc.expected('the end of the text after the date')
        report(&sc, diag)
        return err
    dt := sc.finish(&p, 0) !else |err|:
        report(&sc, diag)
        return err
    return dt.date()

--| Parses a UTC offset such as `+05:30`, `-0330`, `+09` or `Z` and returns the minutes east of UTC.
fn parse_offset(s str) -> !int:
    sc := Scan{src=s}
    off := sc.offset()!
    if !sc.at_end():
        return error.Syntax
    return off

--| Returns an offset in minutes as `+05:30`. Panics when the offset is out of range.
fn format_offset(offset int) -> str:
    if !valid_offset(offset):
        panic('A UTC offset is -1439 to 1439 minutes.')
    return str(put_offset({}, offset, true))

-- Time zones.

#[bind]
-fn tz_read_(name str) -> str

#[bind]
-fn tz_local_() -> str

#[bind]
-fn tz_local_data_() -> str

-fn utc_zone() -> Zone:
    return {kind=2, name_='UTC', rule={has=true, std_abbr='UTC'}}

--| Returns the time zone of an IANA name such as `Asia/Seoul` or `America/New_York`, read from the time zone
--| database of the system: the directory in `TZDIR`, then `/usr/share/zoneinfo` and the like.
--| `UTC` is always there. `error.NotFound` when the system has no zone by that name, or no database
--| (Windows, wasm): give the data with `zone_from_tzif` there.
fn zone(name str) -> !Zone:
    if name == 'UTC':
        return utc_zone()
    data := tz_read_(name)
    if data.len() == 0:
        return error.NotFound
    return db_zone(name, data)

-fn db_zone(name str, data str) -> !Zone:
    z := tzif_zone(name, data)!
    z.db = true
    return z

--| Returns the time zone of the system: what `TZ` says (a zone name, the path of a TZif file or a POSIX rule),
--| or else `/etc/localtime`. `error.NotFound` when the system does not say, or says something that can not be read.
fn local() -> !Zone:
    spec := tz_local_()
    if spec.len() == 0:
        return error.NotFound
    arg := spec[1..]
    switch spec[0]:
        case 'U':
            return utc_zone()
        case 'T':
            if arg == 'UTC':
                return utc_zone()
            data := tz_read_(arg)
            if data.len() > 0:
                return db_zone(arg, data) !else:
                    return error.NotFound
            return zone_from_posix(arg) !else:
                return error.NotFound
        else:
            data := tz_local_data_()
            if data.len() == 0:
                return error.NotFound
            if arg.len() == 0:
                return tzif_zone('Local', data) !else:
                    return error.NotFound
            return db_zone(arg, data) !else:
                return error.NotFound

--| Returns the time zone of a TZif file (RFC 9636), the format of the files in a zoneinfo directory.
--| `error.Syntax` when the data is not a TZif file.
fn zone_from_tzif(name str, data []byte) -> !Zone:
    return tzif_zone(name, str(data))

--| Returns the time zone of a POSIX `TZ` rule such as `KST-9` or `EST5EDT,M3.2.0,M11.1.0`.
--| The offset in a rule is positive west of UTC.
fn zone_from_posix(tz str) -> !Zone:
    return {kind=2, name_=tz, rule=parse_rule(tz)!}

--| Returns the name that the zone was made with.
fn (&Zone) name() -> str:
    return self.name_

--| Returns the UTC offset of the zone at an instant, in minutes east of UTC. An offset of the database that is
--| not a whole minute (local mean time, mostly before 1920) is rounded to the minute.
fn (&Zone) offset_at(t Time) -> int:
    return self.info_at(t.sec).off

--| Whether daylight saving time is on at an instant.
fn (&Zone) is_dst(t Time) -> bool:
    return self.info_at(t.sec).dst

--| Returns the abbreviation of the zone at an instant, such as `KST`, `EST` or `EDT`.
fn (&Zone) abbreviation(t Time) -> str:
    return self.info_at(t.sec).abbr

--| Returns a date and time of day in the zone. A time that the zone has twice or not at all is read as
--| `Disambiguation.compatible` says. `error.Range` when a field is out of range or the day does not exist.
fn (&Zone) datetime(year int, month int, day int, hour int, minute int, second int) -> !DateTime:
    return self.datetime(year, month, day, hour, minute, second, 0, .compatible)

fn (&Zone) datetime(year int, month int, day int, hour int, minute int, second int, nsec int, how Disambiguation) -> !DateTime:
    d := date(year, month, day)!
    if hour < 0 or hour > 23 or minute < 0 or minute > 59 or second < 0 or second > 59:
        return error.Range
    if nsec < 0 or nsec >= NsPerSec:
        return error.Range
    return self.at_local(d.days * SecsPerDay + hour * 3600 + minute * 60 + second, nsec, how)

-fn in_zone(sec int, nsec int, zone Zone) -> DateTime:
    if zone.kind == 0:
        return {sec=sec, nsec=nsec, off=0}
    return {sec=sec, nsec=nsec, off=zone.info_at(sec).off, tz=zone}

-- The value of a date and time of day in the zone. `local` is the seconds from 1970-01-01T00:00:00 of that
-- clock reading.
-fn (&Zone) at_local(local int, nsec int, how Disambiguation) -> !DateTime:
    if self.kind == 0:
        return error.Range
    -- The offsets a day before and a day after are those on each side of a transition near `local`.
    before := self.info_at(local - SecsPerDay).off
    after := self.info_at(local + SecsPerDay).off
    first := local - before * 60
    second := local - after * 60
    sec := first
    if before != after:
        ok1 := self.info_at(first).off == before
        ok2 := self.info_at(second).off == after
        if ok1 and ok2:
            -- The clock was set back: the time comes twice.
            switch how:
                case .reject:
                    return error.Ambiguous
                case .later:
                    if second > first:
                        sec = second
                else:
                    if second < first:
                        sec = second
        else ok2 and !ok1:
            sec = second
        else !ok1:
            -- The clock was set forward: the time is skipped.
            switch how:
                case .reject:
                    return error.Skipped
                case .earlier:
                    sec = second
                else:
                    sec = first
    if !valid_instant(sec):
        return error.Range
    return {sec=sec, nsec=nsec, off=self.info_at(sec).off, tz=self.*}

-fn (&Zone) info_at(sec int) -> ZoneInfo:
    if self.kind != 1:
        return self.rule.info_at(sec)
    n := self.ntrans
    if n == 0 or sec < self.trans(0):
        if n == 0 and self.rule.has:
            return self.rule.info_at(sec)
        -- Before the first transition: the first type of the file.
        return self.type_info(0)
    if self.rule.has and sec >= self.trans(n - 1):
        return self.rule.info_at(sec)
    -- The last transition at or before `sec`.
    lo := 0
    hi := n - 1
    while lo < hi:
        mid := (lo + hi + 1) / 2
        if self.trans(mid) <= sec:
            lo = mid
        else:
            hi = mid - 1
    return self.type_info(int(self.data[self.p_idx + lo]))

-fn (&Zone) trans(i int) -> int:
    return read_be(self.data, self.p_trans + i * self.wide, self.wide)

-fn (&Zone) type_info(i int) -> ZoneInfo:
    p := self.p_types + i * 6
    start := self.p_abbr + int(self.data[p + 5])
    end := start
    while int(self.data[end]) != 0:
        end += 1
    return {off=floor_div(read_be(self.data, p, 4) + 30, 60), dst=int(self.data[p + 4]) != 0, abbr=self.data[start..end]}

-- Reads a big endian signed integer of `n` bytes, 4 or 8.
-fn read_be(data str, pos int, n int) -> int:
    v := 0
    for 0..n |i|:
        v = (v << 8) || int(data[pos + i])
    if n == 4 and v >= 2147483648:
        v -= 4294967296
    return v

-fn tzif_magic(data str, pos int) -> bool:
    return pos + 44 <= data.len() and data[pos..pos + 4] == 'TZif'

-fn tzif_zone(name str, data str) -> !Zone:
    if !tzif_magic(data, 0):
        return error.Syntax
    version := int(data[4])
    pos := 0
    wide := 4
    if version != 0:
        -- Version 2 and later: the first block has 32 bit times. Skip it for the block of 64 bit times.
        timecnt := read_be(data, 32, 4)
        typecnt := read_be(data, 36, 4)
        charcnt := read_be(data, 40, 4)
        leapcnt := read_be(data, 28, 4)
        if timecnt < 0 or typecnt < 0 or charcnt < 0 or leapcnt < 0 or timecnt + typecnt + charcnt + leapcnt > data.len():
            return error.Syntax
        isut := read_be(data, 20, 4)
        isstd := read_be(data, 24, 4)
        if isut < 0 or isstd < 0 or isut + isstd > data.len():
            return error.Syntax
        pos = 44 + timecnt * 5 + typecnt * 6 + charcnt + leapcnt * 8 + isstd + isut
        wide = 8
        if !tzif_magic(data, pos):
            return error.Syntax
    isut := read_be(data, pos + 20, 4)
    isstd := read_be(data, pos + 24, 4)
    leapcnt := read_be(data, pos + 28, 4)
    timecnt := read_be(data, pos + 32, 4)
    typecnt := read_be(data, pos + 36, 4)
    charcnt := read_be(data, pos + 40, 4)
    if isut < 0 or isstd < 0 or leapcnt < 0 or timecnt < 0 or typecnt < 1 or typecnt > 256 or charcnt < 1:
        return error.Syntax
    if isut + isstd + leapcnt + timecnt + charcnt > data.len():
        return error.Syntax
    z := Zone{kind=1, name_=name, data=data, wide=wide, ntrans=timecnt, ntypes=typecnt}
    z.p_trans = pos + 44
    z.p_idx = z.p_trans + timecnt * wide
    z.p_types = z.p_idx + timecnt
    z.p_abbr = z.p_types + typecnt * 6
    end := z.p_abbr + charcnt + leapcnt * (wide + 4) + isstd + isut
    if end > data.len():
        return error.Syntax
    -- Every abbreviation ends inside the table.
    if int(data[z.p_abbr + charcnt - 1]) != 0:
        return error.Syntax
    for 0..typecnt |i|:
        p := z.p_types + i * 6
        off := floor_div(read_be(data, p, 4) + 30, 60)
        if !valid_offset(off) or int(data[p + 5]) >= charcnt:
            return error.Syntax
    last := 0
    for 0..timecnt |i|:
        at := z.trans(i)
        if (i > 0 and at <= last) or int(data[z.p_idx + i]) >= typecnt:
            return error.Syntax
        last = at
    if version != 0:
        -- The footer: a line with the rule for the time after the last transition, or an empty line.
        if end >= data.len() or data[end] != '\n':
            return error.Syntax
        stop := end + 1
        while stop < data.len() and data[stop] != '\n':
            stop += 1
        if stop >= data.len():
            return error.Syntax
        if stop > end + 1:
            z.rule = parse_rule(data[end + 1..stop])!
    return z

-fn (&Rule) info_at(sec int) -> ZoneInfo:
    if !self.dst:
        return {off=self.std_off, dst=false, abbr=self.std_abbr}
    year := civil_from_days(floor_div(sec + self.std_off * 60, SecsPerDay)).y
    -- The start is a reading of the clock in standard time, the end one in daylight saving time.
    start := rule_local(year, &self.start) - self.std_off * 60
    end := rule_local(year, &self.end) - self.dst_off * 60
    on := false
    if start < end:
        on = sec >= start and sec < end
    else:
        on = !(sec >= end and sec < start)
    if on:
        return {off=self.dst_off, dst=true, abbr=self.dst_abbr}
    return {off=self.std_off, dst=false, abbr=self.std_abbr}

-- The clock reading of a rule day in a year, in seconds from 1970-01-01T00:00:00.
-fn rule_local(year int, r &RuleDay) -> int:
    jan1 := days_from_civil(year, 1, 1)
    day := jan1 + r.d
    switch r.kind:
        case 0:
            first := days_from_civil(year, r.m, 1)
            -- Sunday is 0 in a rule.
            wd := (weekday_num(first) + 1) % 7
            day = first + floor_mod(r.d - wd, 7) + (r.w - 1) * 7
            if day >= first + days_in_month(year, r.m):
                day -= 7
        case 1:
            day = jan1 + r.d - 1
            if r.d >= 60 and is_leap_year(year):
                day += 1
        else:
            pass
    return day * SecsPerDay + r.secs

-- Parses a POSIX `TZ` string: `std offset [dst [offset] [,start[/time],end[/time]]]`.
-fn parse_rule(tz str) -> !Rule:
    sc := Scan{src=tz}
    var r Rule = {has=true}
    r.std_abbr = sc.tz_abbr()!
    r.std_off = -floor_div(sc.tz_secs(24)! + 30, 60)
    if sc.at_end():
        if !valid_offset(r.std_off):
            return error.Syntax
        return r
    r.dst = true
    r.dst_abbr = sc.tz_abbr()!
    r.dst_off = r.std_off + 60
    if !sc.at_end() and sc.peek() != ',':
        r.dst_off = -floor_div(sc.tz_secs(24)! + 30, 60)
    if !valid_offset(r.std_off) or !valid_offset(r.dst_off):
        return error.Syntax
    if sc.at_end():
        -- No days: the rule of the United States, as the C libraries read it.
        r.start = {kind=0, m=3, w=2, d=0}
        r.end = {kind=0, m=11, w=1, d=0}
        return r
    sc.literal(',', '`,`')!
    r.start = sc.tz_day()!
    sc.literal(',', '`,`')!
    r.end = sc.tz_day()!
    if !sc.at_end():
        return error.Syntax
    return r

-- An abbreviation: three or more letters, or anything but `>` in `<...>`.
-fn (&Scan) tz_abbr() -> !str:
    start := self.pos
    if !self.at_end() and self.peek() == '<':
        while !self.at_end() and self.peek() != '>':
            self.pos += 1
        if self.at_end() or self.pos - start < 2:
            return error.Syntax
        self.pos += 1
        return self.src[start + 1..self.pos - 1]
    while !self.at_end() and (str.is_ascii_lower(self.peek()) or str.is_ascii_upper(self.peek())):
        self.pos += 1
    if self.pos - start < 3:
        return error.Syntax
    return self.src[start..self.pos]

-- `[+-]hh[:mm[:ss]]` in seconds, with at most `max_hours` hours.
-fn (&&Scan) tz_secs(max_hours int) -> !int:
    neg := false
    if !self.at_end() and (self.peek() == '+' or self.peek() == '-'):
        neg = self.peek() == '-'
        self.pos += 1
    h := self.digits(1, 3, 'hours')!
    m := 0
    s := 0
    if !self.at_end() and self.peek() == ':':
        self.pos += 1
        m = self.digits(1, 2, 'minutes')!
        if !self.at_end() and self.peek() == ':':
            self.pos += 1
            s = self.digits(1, 2, 'seconds')!
    if h > max_hours or m > 59 or s > 59:
        return error.Syntax
    v := h * 3600 + m * 60 + s
    if neg:
        return -v
    return v

-fn (&&Scan) tz_day() -> !RuleDay:
    var r RuleDay = {}
    if self.at_end():
        return error.Syntax
    c := self.peek()
    if c == 'M':
        self.pos += 1
        r.kind = 0
        r.m = self.digits(1, 2, 'a month')!
        self.literal('.', '`.`')!
        r.w = self.digits(1, 1, 'a week')!
        self.literal('.', '`.`')!
        r.d = self.digits(1, 1, 'a weekday')!
        if r.m < 1 or r.m > 12 or r.w < 1 or r.w > 5 or r.d > 6:
            return error.Syntax
    else c == 'J':
        self.pos += 1
        r.kind = 1
        r.d = self.digits(1, 3, 'a day of the year')!
        if r.d < 1 or r.d > 365:
            return error.Syntax
    else:
        r.kind = 2
        r.d = self.digits(1, 3, 'a day of the year')!
        if r.d > 365:
            return error.Syntax
    if !self.at_end() and self.peek() == '/':
        self.pos += 1
        r.secs = self.tz_secs(167)!
    return r

-- RFC 9557: an RFC 3339 timestamp with the time zone in brackets.

--| Returns the value as RFC 9557: RFC 3339 with the name of the time zone in brackets, such as
--| `2026-07-04T08:00:00-04:00[America/New_York]`. `time.parse_zoned` reads it back with its zone.
--| A value without a zone, or in a zone that was not read from the time zone database by `time.zone` or
--| `time.local` (one of `zone_from_tzif` or `zone_from_posix`, or the zone of the system when its name is not
--| known), is written as `format()` writes it: `parse_zoned` could not find the zone by its name.
fn (&DateTime) format_zoned() -> str:
    named := (self.tz.db and is_zone_name(self.tz.name_)) or (self.tz.kind == 2 and self.tz.name_ == 'UTC')
    if !named:
        return self.format()
    text := self.format()
    if self.off == 0:
        -- `Z` says that the offset of the place is not known, so the offset is written out.
        text = text[0..text.len() - 1] + '+00:00'
    return text + '[' + self.tz.name_ + ']'

-- Whether `name` has the shape of a name of the time zone database. The same rule as in `time.zig`.
-fn is_zone_name(name str) -> bool:
    if name.len() == 0 or name.len() > 255:
        return false
    prev := byte('/')
    for 0..name.len() |i|:
        c := name[i]
        if c == '/':
            if prev == '/':
                return false
        else !(str.is_ascii_digit(c) or str.is_ascii_alpha(c) or c == '+' or c == '-' or c == '_'):
            return false
        prev = c
    return prev != '/'

--| Parses an RFC 9557 timestamp: RFC 3339 with a time zone in brackets, such as
--| `2026-07-04T08:00:00-04:00[America/New_York]`. The zone is read with `time.zone`, and the value is in it.
--| The offset says which of two readings it is when the clock was set back. With `Z` in the place of the
--| offset, or without one, the zone gives the offset. A text without brackets is read as `time.parse` reads it,
--| and `[+09:00]` is a fixed offset. Other tags in brackets such as `[u-ca=gregory]` are skipped.
--| `error.NotFound` when the system does not have the zone, and `error.Conflict` when the offset in the text
--| is not the offset of the zone at that time: the rules of the zone changed after the text was written.
fn parse_zoned(s str) -> !DateTime:
    var diag Diag = {}
    return parse_zoned(s, &&diag)

fn parse_zoned(s str, diag &&Diag) -> !DateTime:
    diag.msg = ''
    diag.pos = 0
    sc := Scan{src=s}
    return sc.rfc9557() !else |err|:
        report(&sc, diag)
        return err

-fn (&&Scan) rfc9557() -> !DateTime:
    var p Parts = {}
    self.clock_part(&p)!
    zulu := false
    if !self.at_end() and self.peek() != '[':
        zulu = self.peek() == 'Z' or self.peek() == 'z'
        p.off = self.offset()!
        p.has_off = true
    -- The tags. The first one without `=` is the time zone.
    name := ''
    name_pos := 0
    while !self.at_end() and self.peek() == '[':
        open := self.pos
        self.pos += 1
        critical := false
        if !self.at_end() and self.peek() == '!':
            critical = true
            self.pos += 1
        start := self.pos
        while !self.at_end() and self.peek() != ']':
            self.pos += 1
        if self.at_end():
            self.fail(open, 'This `[` is not closed.')
            return error.Syntax
        tag := self.src[start..self.pos]
        self.pos += 1
        if tag.index('=') != none:
            if critical:
                self.fail(open, 'The tag `' + tag + '` is marked as required with `!`, and it is not known here.')
                return error.Syntax
            continue
        if name.len() > 0 or tag.len() == 0:
            self.fail(open, 'Expected one time zone in brackets, such as `[Asia/Seoul]`.')
            return error.Syntax
        name = tag
        name_pos = start
    if !self.at_end():
        return self.expected('the end of the text, or a time zone in brackets')
    if name.len() == 0:
        if !p.has_off:
            self.fail(self.pos, 'The text has no UTC offset and no time zone in brackets.')
            return error.Syntax
        return self.finish(&p, 0)
    if name[0] == '+' or name[0] == '-':
        -- A fixed offset in the brackets.
        sub := Scan{src=name}
        fixed := sub.offset() !else |err|:
            self.fail(name_pos, 'Expected an offset such as `+09:00` in the brackets.')
            return err
        if !sub.at_end():
            self.fail(name_pos, 'Expected an offset such as `+09:00` in the brackets.')
            return error.Syntax
        if p.has_off and !zulu and p.off != fixed:
            self.fail(name_pos, 'The offset of the text is ' + format_offset(p.off) + ' and the offset in the brackets is ' + format_offset(fixed) + '.')
            return error.Conflict
        if p.has_off:
            dt := self.finish(&p, 0)!
            return dt.to_offset(fixed)
        return self.finish(&p, fixed)
    z := zone(name) !else |err|:
        if err == error.NotFound:
            self.fail(name_pos, 'The system has no time zone `' + name + '`.')
        else:
            self.fail(name_pos, 'The data of the time zone `' + name + '` can not be read.')
        return err
    dt := self.finish(&p, 0)!
    if !p.has_off:
        -- A clock reading in the zone.
        return dt.replace_zone(z) !else |err|:
            self.fail(0, 'The time is out of range: years 1 to 9999.')
            return err
    res := dt.to_zone(z)
    if !zulu and res.off != p.off:
        self.fail(name_pos, 'The offset of the text is ' + format_offset(p.off) + ', and `' + name + '` is at ' + format_offset(res.off) + ' at that time.')
        return error.Conflict
    return res

