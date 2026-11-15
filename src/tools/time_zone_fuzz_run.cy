#!cyber

-- Compares the time zones of the `time` module with the answers of Python's `zoneinfo` from
-- `time_zone_fuzz_gen.py`. Both read the time zone database of the system.
-- Usage: cyber src/tools/time_zone_fuzz_run.cy <cases.json>
use json
use os
use time

doc := json.parse(os.read_file_str(os.args()[1])!)!
count := 0
bad := 0
var zones Map[str, time.Zone] = {}
for doc.as_array().? |c|:
    count += 1
    name := c['zone'].as_str().?
    if !zones.contains(name):
        zones[name] = time.zone(name)!
    z := zones[name]
    sec := c['sec'].as_int().?
    t := time.unix(sec)!
    dt := t.to_zone(z)
    abbr := c['abbr'].as_str().?
    got := '%{z.offset_at(t)} %{z.is_dst(t)} %{z.abbreviation(t)} %{dt.format('%Y-%m-%d %H:%M:%S')!}'
    want := '%{c['off'].as_int().?} %{c['dst'].as_bool().?} %{abbr} %{c['text'].as_str().?}'
    if got != want:
        bad += 1
        print('AT %{name} %{sec}: got %{got}, python %{want}')
    if dt.offset() != z.offset_at(t) or dt.format('%Z')! != abbr or dt.zone().?.name() != name:
        bad += 1
        print('VALUE %{name} %{sec}: %{dt.format()} %{dt.format('%Z')!}')
    -- The value as text with its zone, and back.
    back := time.parse_zoned(dt.format_zoned())!
    if back != dt or back.zone().?.name() != name:
        bad += 1
        print('ZONED %{name} %{sec}: %{dt.format_zoned()} gives %{back.format_zoned()}')
    -- A clock reading, read each way.
    l := c['local']
    f0 := c['fold0'].as_int().?
    f1 := c['fold1'].as_int().?
    lo := f0
    hi := f1
    if f1 < f0:
        lo = f1
        hi = f0
    y := l[0].as_int().?
    mo := l[1].as_int().?
    d := l[2].as_int().?
    h := l[3].as_int().?
    mi := l[4].as_int().?
    s := l[5].as_int().?
    id := '%{name} %{y}-%{mo}-%{d} %{h}:%{mi}:%{s}'
    a := z.datetime(y, mo, d, h, mi, s)!
    if a.time().unix() != f0:
        bad += 1
        print('LOCAL %{id}: compatible %{a.time().unix()}, python fold=0 %{f0}')
    e := z.datetime(y, mo, d, h, mi, s, 0, .earlier)!
    if e.time().unix() != lo:
        bad += 1
        print('LOCAL %{id}: earlier %{e.time().unix()}, python %{lo}')
    r := z.datetime(y, mo, d, h, mi, s, 0, .later)!
    if r.time().unix() != hi:
        bad += 1
        print('LOCAL %{id}: later %{r.time().unix()}, python %{hi}')
    rejected := false
    try:
        _ = z.datetime(y, mo, d, h, mi, s, 0, .reject)!
    else:
        rejected = true
    if rejected != (f0 != f1):
        bad += 1
        print('LOCAL %{id}: reject %{rejected}, python %{f0} %{f1}')
    -- The same reading through the other ways in.
    if time.parse_zoned(r.format_zoned())! != r or time.parse_zoned(e.format_zoned())! != e:
        bad += 1
        print('ZONED %{id}: %{r.format_zoned()} or %{e.format_zoned()} does not read back')
    -- Without an offset, the text is the clock reading.
    if time.parse_zoned(a.format('%Y-%m-%dT%H:%M:%S')! + '[' + name + ']')! != a:
        bad += 1
        print('ZONED %{id}: the reading without an offset differs')
    if time.date(y, mo, d)!.at(h, mi, s, z)! != a or time.datetime(y, mo, d, h, mi, s)!.replace_zone(z)! != a:
        bad += 1
        print('LOCAL %{id}: `Date.at` or `replace_zone` differs')
print('%{count} cases, %{bad} differ')
