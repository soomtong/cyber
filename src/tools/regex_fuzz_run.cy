#!cyber

-- Compares the `regex` module with ripgrep's answers from `regex_fuzz_gen.py`.
-- Usage: cyber src/tools/regex_fuzz_run.cy <cases.json>
use json
use regex
use os

doc := json.parse(os.read_file(os.args()[1])!)!
count := 0
bad := 0
ours_only := 0
for doc.as_array().? |c|:
    pat := c['regex'].as_str().?
    hay := c['hay'].as_str().?
    count += 1
    var diag regex.Diag = {}
    var re ?regex.Regex = none
    try:
        re = regex.compile(pat, &diag)!
    else:
        pass
    rejected := c['matches'].is_null()
    if re == none:
        -- ripgrep wraps the pattern in `(?:...)`, which closes a stray `)`.
        if !rejected and diag.msg.index('closes no group') == none and diag.msg.index('is not closed') == none:
            ours_only += 1
            print('REJECT `%{pat}`: %{diag.msg}')
        continue
    if rejected:
        -- ripgrep's `(?:...)` wrapper is swallowed by a comment of the `x` flag.
        if pat.index('#') != none:
            continue
        bad += 1
        print('ACCEPT `%{pat}`: ripgrep rejects it')
        continue
    -- ripgrep searches bytes, so its empty matches also fall inside a code point. It searches a line, and the
    -- empty match at the end of the line is not always there. Both are left out.
    got := ''
    for re.?.find_all(hay) |m|:
        if m.end > m.start or m.end < hay.len():
            got += '%{m.start}-%{m.end} '
    want := ''
    for c['matches'].as_array().? |m|:
        ms := m[0].as_int().?
        me := m[1].as_int().?
        if ms == me:
            if ms >= hay.len():
                continue
            if (int(hay[ms]) && 0xc0) == 0x80:
                continue
        want += '%{ms}-%{me} '
    if got != want:
        bad += 1
        print('DIFF `%{pat}` on `%{hay}`: got %{got}, ripgrep %{want}')
print('%{count} cases, %{bad} differ, %{ours_only} rejected only here')
