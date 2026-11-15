-- Reads the TZif files in `src/test/assets/time-zone` (tzdata 2026f) and checks what they say against the
-- answers of Python's `zoneinfo` for the same files. An offset that is not a whole minute (LMT) is rounded.
use os
use time
use t 'test'

fn load(name str, file str) -> !time.Zone:
    data := os.read_file('src/test/assets/time-zone/' + file + '.tzif')!
    return time.zone_from_tzif(name, data)!

fn at(z &time.Zone, utc str, want str) -> !void:
    dt := time.parse(utc)!.to_zone(z.*)
    t.eq(want, dt.format('%Y-%m-%d %H:%M:%S %Z %z')! + ' ' + str(z.is_dst(dt.time())))

ny := load('America/New_York', 'America_New_York')!
seoul := load('Asia/Seoul', 'Asia_Seoul')!
lhi := load('Australia/Lord_Howe', 'Australia_Lord_Howe')!
dublin := load('Europe/Dublin', 'Europe_Dublin')!
t.eq('America/New_York', ny.name())

at(&ny, '1883-11-18T16:59:59Z', '1883-11-18 12:03:59 LMT -0456 false')!
at(&ny, '1883-11-18T17:00:00Z', '1883-11-18 12:00:00 EST -0500 false')!
at(&ny, '1918-03-31T07:00:00Z', '1918-03-31 03:00:00 EDT -0400 true')!
at(&ny, '1945-08-14T23:00:00Z', '1945-08-14 19:00:00 EPT -0400 true')!
at(&ny, '1974-01-06T07:00:00Z', '1974-01-06 03:00:00 EDT -0400 true')!
at(&ny, '2007-03-11T06:59:59Z', '2007-03-11 01:59:59 EST -0500 false')!
at(&ny, '2007-03-11T07:00:00Z', '2007-03-11 03:00:00 EDT -0400 true')!
at(&ny, '2037-11-01T05:59:59Z', '2037-11-01 01:59:59 EDT -0400 true')!
at(&ny, '2037-11-01T06:00:00Z', '2037-11-01 01:00:00 EST -0500 false')!
at(&ny, '2038-03-14T07:00:00Z', '2038-03-14 03:00:00 EDT -0400 true')!
at(&ny, '2400-07-01T00:00:00Z', '2400-06-30 20:00:00 EDT -0400 true')!
at(&seoul, '1900-01-01T00:00:00Z', '1900-01-01 08:28:00 LMT +0828 false')!
at(&seoul, '1910-01-01T00:00:00Z', '1910-01-01 08:30:00 KST +0830 false')!
at(&seoul, '1950-01-01T00:00:00Z', '1950-01-01 09:00:00 KST +0900 false')!
at(&seoul, '1960-06-01T00:00:00Z', '1960-06-01 09:30:00 KDT +0930 true')!
at(&seoul, '1962-01-01T00:00:00Z', '1962-01-01 09:00:00 KST +0900 false')!
at(&seoul, '1987-07-01T00:00:00Z', '1987-07-01 10:00:00 KDT +1000 true')!
at(&seoul, '1988-07-01T00:00:00Z', '1988-07-01 10:00:00 KDT +1000 true')!
at(&seoul, '2026-11-15T00:00:00Z', '2026-11-15 09:00:00 KST +0900 false')!
at(&seoul, '9000-01-01T00:00:00Z', '9000-01-01 09:00:00 KST +0900 false')!
at(&lhi, '1980-01-01T00:00:00Z', '1980-01-01 10:00:00 AEST +1000 false')!
at(&lhi, '1981-12-01T00:00:00Z', '1981-12-01 11:30:00 +1130 +1130 true')!
at(&lhi, '1985-12-01T00:00:00Z', '1985-12-01 11:00:00 +11 +1100 true')!
at(&lhi, '2026-01-04T12:00:00Z', '2026-01-04 23:00:00 +11 +1100 true')!
at(&lhi, '2026-04-04T15:29:59Z', '2026-04-05 01:59:59 +1030 +1030 false')!
at(&lhi, '2026-04-04T15:30:00Z', '2026-04-05 02:00:00 +1030 +1030 false')!
at(&lhi, '2026-10-03T15:30:00Z', '2026-10-04 02:30:00 +11 +1100 true')!
at(&lhi, '2100-07-01T00:00:00Z', '2100-07-01 10:30:00 +1030 +1030 false')!
at(&dublin, '1900-01-01T00:00:00Z', '1899-12-31 23:35:00 DMT -0025 false')!
at(&dublin, '1917-01-01T00:00:00Z', '1917-01-01 00:00:00 GMT +0000 false')!
at(&dublin, '1968-12-01T00:00:00Z', '1968-12-01 01:00:00 IST +0100 false')!
at(&dublin, '1970-01-01T00:00:00Z', '1970-01-01 01:00:00 IST +0100 false')!
at(&dublin, '2026-01-04T12:00:00Z', '2026-01-04 12:00:00 GMT +0000 false')!
at(&dublin, '2026-03-29T00:59:59Z', '2026-03-29 00:59:59 GMT +0000 false')!
at(&dublin, '2026-03-29T01:00:00Z', '2026-03-29 02:00:00 IST +0100 true')!
at(&dublin, '2026-07-04T12:00:00Z', '2026-07-04 13:00:00 IST +0100 true')!
at(&dublin, '2026-10-25T01:00:00Z', '2026-10-25 01:00:00 GMT +0000 false')!
at(&dublin, '2200-01-01T00:00:00Z', '2200-01-01 00:00:00 GMT +0000 false')!

-- A clock reading in a zone, from the transitions of the file and from the rule after them.
t.eq('2007-03-11T03:30:00-04:00', ny.datetime(2007, 3, 11, 2, 30, 0)!.format())
t.eq('2007-11-04T01:30:00-04:00', ny.datetime(2007, 11, 4, 1, 30, 0)!.format())
t.eq('2007-11-04T01:30:00-05:00', ny.datetime(2007, 11, 4, 1, 30, 0, 0, .later)!.format())
t.eq(error.Skipped, ny.datetime(2007, 3, 11, 2, 30, 0, 0, .reject).unwrap_error())
t.eq(error.Ambiguous, ny.datetime(2100, 11, 7, 1, 30, 0, 0, .reject).unwrap_error())
t.eq('2100-03-14T03:30:00-04:00', ny.datetime(2100, 3, 14, 2, 30, 0)!.format())
-- Lord Howe Island moves its clock by half an hour.
t.eq('2026-10-04T02:45:00+11:00', lhi.datetime(2026, 10, 4, 2, 15, 0)!.format())
t.eq('2026-04-05T01:45:00+11:00', lhi.datetime(2026, 4, 5, 1, 45, 0)!.format())
t.eq('2026-04-05T01:45:00+10:30', lhi.datetime(2026, 4, 5, 1, 45, 0, 0, .later)!.format())
-- Korea skipped half an hour when it left +08:30 on 1961-08-10.
t.eq('1961-08-10T00:45:00+09:00', seoul.datetime(1961, 8, 10, 0, 15, 0)!.format())
t.eq('1988-05-08T03:30:00+10:00', seoul.datetime(1988, 5, 8, 2, 30, 0)!.format())

-- Calendar steps keep the time of day, exact steps do not.
d := ny.datetime(2026, 10, 31, 12, 0, 0)!
t.eq('2026-11-01T12:00:00-05:00', d.add_days(1)!.format())
t.eq('2026-11-01T11:00:00-05:00', (d + time.hours(24)).format())
t.eq('2027-03-31T12:00:00-04:00', d.add_months(5)!.format())
t.eq('America/New_York', d.add_months(5)!.zone().?.name())

-- Two values of the same file compare by the bytes of the zone.
t.eq(true, d == load('America/New_York', 'America_New_York')!.datetime(2026, 10, 31, 12, 0, 0)!)
t.eq(false, d == d.to_zone(seoul))
t.eq(true, d.time() == d.to_zone(seoul).time())

-- A file that is cut short, or changed, is not a zone.
bytes := os.read_file('src/test/assets/time-zone/Asia_Seoul.tzif')!
for {0, 3, 43, 44, 100, 300, bytes.len() - 6, bytes.len() - 1} |n|:
    t.eq(error.Syntax, time.zone_from_tzif('cut', bytes[0..n]).unwrap_error())
t.eq(617, bytes.len())

-- The zone of the system, where it has one, and the database, where it has that zone.
try:
    here := time.local()!
    t.eq(true, here.name().len() > 0)
    t.eq(here.offset_at(time.now()), time.now().to_zone(here).offset())
else |err|:
    t.eq(error.NotFound, err)
try:
    sys := time.zone('Asia/Seoul')!
    t.eq(540, sys.offset_at(time.now()))
    t.eq('KST', sys.abbreviation(time.now()))
    -- RFC 9557 reads the zone from the database by its name.
    z := time.parse_zoned('1988-07-01T10:00:00+10:00[Asia/Seoul]')!
    t.eq('1988-07-01T10:00:00+10:00[Asia/Seoul]', z.format_zoned())
    t.eq('1988-12-01T10:00:00+09:00[Asia/Seoul]', z.add_months(5)!.format_zoned())
    t.eq(error.Conflict, time.parse_zoned('1988-07-01T10:00:00+09:00[Asia/Seoul]').unwrap_error())
    t.eq('2026-11-15T09:00:00+09:00[Asia/Seoul]', time.parse_zoned('2026-11-15T00:00:00Z[Asia/Seoul]')!.format_zoned())
else |err|:
    t.eq(error.NotFound, err)

-- A zone from data has a name that `parse_zoned` can not look up: it is written without brackets.
t.eq('2026-10-31T12:00:00-04:00', d.format_zoned())
t.eq('2026-11-01T01:30:00-05:00', ny.datetime(2026, 11, 1, 1, 30, 0, 0, .later)!.format_zoned())
office := load('Office', 'Asia_Seoul')!
t.eq('2026-11-15T09:00:00+09:00', time.parse('2026-11-15T00:00:00Z')!.to_zone(office).format_zoned())

--cytest: pass