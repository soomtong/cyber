-- Runs the conformance fixtures in `src/test/assets/regex-spec`: the test data of the Rust `regex` crate,
-- which is what ripgrep matches with.
use json
use regex
use os
use t 'test'

files := []str{
    'anchored', 'bytes', 'crazy', 'empty', 'expensive', 'flags', 'fowler-basic', 'fowler-nullsubexpr',
    'fowler-repetition', 'iter', 'misc', 'multiline', 'no-unicode', 'regression', 'substring',
    'unicode', 'utf8', 'word-boundary-special', 'word-boundary',
}

fn hex_val(c byte) -> int:
    if c <= '9':
        return int(c) - '0'
    return int(c) - 'a' + 10

fn unhex(s str) -> str:
    bytes := []byte(s.len() / 2, 0)
    for 0..bytes.len() |i|:
        bytes[i] = byte(hex_val(s[i * 2]) * 16 + hex_val(s[i * 2 + 1]))
    return str(bytes)

--| The groups of one match as text: `0-3 1-2 none`.
fn show(c &regex.Captures, groups int) -> str:
    out := ''
    for 0..groups |g|:
        if g > 0:
            out += ' '
        if c.get(g) |m|:
            out += '%{m.start}-%{m.end}'
        else:
            out += 'none'
    return out

fn expected(m json.Value, groups int) -> str:
    out := ''
    for 0..groups |g|:
        if g > 0:
            out += ' '
        span := m[g]
        if span.is_null():
            out += 'none'
        else:
            out += '%{span[0].as_int().?}-%{span[1].as_int().?}'
    return out

count := 0
failed := 0
for files |f|:
    doc := json.parse(os.read_file('src/test/assets/regex-spec/' + f + '.json')!)!
    for doc.as_array().? |test|:
        name := test['name'].as_str().?
        pat := test['regex'].as_str().?
        hay := unhex(test['hay'].as_str().?)
        compiles := test['compiles'].as_bool() ?else true
        caps := test['caps'].as_bool() ?else false
        limit := test['limit'].as_int() ?else -1
        start := test['start'].as_int() ?else 0
        count += 1
        var diag regex.Diag = {}
        var re ?regex.Regex = none
        try:
            re = regex.compile(pat, &diag)!
        else:
            pass
        if re == none:
            if compiles:
                failed += 1
                print('FAIL %{name}: `%{pat}` does not compile: %{diag.msg}')
            continue
        if !compiles:
            failed += 1
            print('FAIL %{name}: `%{pat}` compiles')
            continue
        r := re.?
        want := test['matches'].as_array().?
        var got []regex.Captures = {}
        if start > 0 or limit == 1:
            if r.captures(hay, start) |c|:
                got.append(c)
        else:
            got = r.captures_all(hay)
        n := got.len()
        if limit >= 0 and n > limit:
            n = limit
        ok := n == want.len()
        detail := 'found %{n} matches, expected %{want.len()}'
        if ok:
            for 0..n |i|:
                groups := 1
                if caps:
                    groups = want[i].len()
                    if groups != r.captures_len():
                        ok = false
                        detail = 'the pattern has %{r.captures_len()} groups, expected %{groups}'
                        break
                g := show(&got[i], groups)
                w := expected(want[i], groups)
                if g != w:
                    ok = false
                    detail = 'match %{i} is %{g}, expected %{w}'
                    break
        if ok and start == 0 and r.is_match(hay) != (want.len() > 0):
            ok = false
            detail = 'is_match disagrees'
        if !ok:
            failed += 1
            print('FAIL %{name}: `%{pat}`: %{detail}')
t.eq(820, count)
t.eq(0, failed)

--cytest: pass
