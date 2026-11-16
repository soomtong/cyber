#!cyber

-- Compares the `time` module with the answers of Python's `datetime` from `time_fuzz_gen.py`.
-- Usage: cyber src/tools/time_fuzz_run.cy <cases.json>
use json
use os
use time

doc := json.parse(os.read_file(os.args()[1])!)!
count := 0
bad := 0
for doc.as_array().? |c|:
    count += 1
    sec := c['sec'].as_int().?
    nsec := c['nsec'].as_int().?
    off := c['off'].as_int().?
    id := '%{sec}.%{nsec} at %{off}'
    dt := time.unix(sec, nsec)!.to_offset(off)!
    f := c['fields']
    d := dt.date()
    wk := d.iso_week()
    got := '%{dt.year()} %{dt.month()} %{dt.day()} %{dt.hour()} %{dt.minute()} %{dt.second()} %{d.iso_weekday() - 1} %{dt.day_of_year()} %{wk.year} %{wk.week}'
    want := ''
    for 0..10 |i|:
        if i > 0:
            want += ' '
        want += str(f[i].as_int().?)
    if got != want:
        bad += 1
        print('FIELDS %{id}: got %{got}, python %{want}')
    text := c['rfc3339'].as_str().?
    if dt.format() != text:
        bad += 1
        print('RFC3339 %{id}: got %{dt.format()}, python %{text}')
    back := time.parse(text)!
    if back != dt:
        bad += 1
        print('PARSE %{text}: got %{back.format()}')
    -- The fields make the same value again.
    made := time.datetime(dt.year(), dt.month(), dt.day(), dt.hour(), dt.minute(), dt.second(), nsec, off)!
    if made != dt or d.at(dt.hour(), dt.minute(), dt.second(), nsec, off)! != dt:
        bad += 1
        print('MAKE %{id}: got %{made.format()}')
    -- Month and day shifts.
    months := c['months'].as_int().?
    shifted := 'none'
    try:
        shifted = d.add_months(months)!.format()
    else:
        pass
    want_shifted := c['shifted'].as_str() ?else 'none'
    if shifted != want_shifted:
        bad += 1
        print('MONTHS %{d.format()} + %{months}: got %{shifted}, python %{want_shifted}')
    if shifted != 'none':
        -- The time of day stays when a `DateTime` moves by months. Near the ends of the range the instant
        -- can be out of range although the date is not.
        try:
            moved := dt.add_months(months)!
            if moved.date().format() != shifted or moved.hour() != dt.hour() or moved.second() != dt.second() or moved.offset() != off:
                bad += 1
                print('MONTHS %{dt.format()} + %{months}: got %{moved.format()}')
        else:
            pass
    days := c['days'].as_int().?
    other := 'none'
    try:
        o := d.add_days(days)!
        other = o.format()
        if o - d != days or time.parse_date(other)! != o:
            bad += 1
            print('DAYS %{d.format()} + %{days}: difference %{o - d}')
    else:
        pass
    want_other := c['other'].as_str() ?else 'none'
    if other != want_other:
        bad += 1
        print('DAYS %{d.format()} + %{days}: got %{other}, python %{want_other}')
    if c['formats'].is_null():
        continue
    for c['formats'].as_array().? |e|:
        fmt := e[0].as_str().?
        out := dt.format(fmt)!
        if out != e[1].as_str().?:
            bad += 1
            print('FORMAT %{id} `%{fmt}`: got `%{out}`, python `%{e[1].as_str().?}`')
    for c['round_trip'].as_array().? |e|:
        fmt := e[0].as_str().?
        src := e[1].as_str().?
        var diag time.Diag = {}
        try:
            p := time.parse_format(src, fmt, &diag)!
            if p != dt:
                bad += 1
                print('STRPTIME `%{src}` by `%{fmt}`: got %{p.format()}, python %{dt.format()}')
        else |err|:
            bad += 1
            print('STRPTIME `%{src}` by `%{fmt}`: %{err} at %{diag.pos}: %{diag.msg}')
print('%{count} cases, %{bad} differ')
