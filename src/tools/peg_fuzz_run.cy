#!cyber

-- Compares the `peg` module with the answers of LPeg's `re` from `peg_fuzz_gen.py`.
-- Usage: cyber src/tools/peg_fuzz_run.cy <cases.json>
use json
use peg
use os

-- The values of the captures as LPeg lists them: a named capture gives none, and the captures inside a string
-- or a substitution capture are part of its text. Those two are told by a text that is not the input text,
-- which the generator makes sure of.
fn values(hay str, c &peg.Capture, out &[]str):
    for c.kids |k|:
        if k.name.len() > 0:
            continue
        out.* = out.*.append(k.text)
        if k.text == hay[k.start..k.end]:
            values(hay, &k, out)

-- A list of bytes in the cases as a string: the input and the captures may hold bytes that are not UTF-8.
fn bytes_str(v json.Value) -> str:
    var buf []byte = {}
    for v.as_array().? |b|:
        buf = buf.append(byte(b.as_int().?))
    return str(buf)

-- Every match of `find_all` as `start-end`, joined with commas.
fn show_all(p &peg.Peg, hay str) -> str:
    out := ''
    for p.find_all(hay) |m|:
        if out.len() > 0:
            out += ','
        out += '%{m.start}-%{m.end}'
    return out

doc := json.parse(os.read_file(os.args()[1])!)!
count := 0
bad := 0
skipped := 0
stricter := 0
for doc.as_array().? |c|:
    src := c['peg'].as_str().?
    hay := bytes_str(c['hay'])
    kind := c['kind'].as_str().?
    count += 1
    var diag peg.Diag = {}
    var p ?peg.Peg = none
    try:
        p = peg.compile(src, &diag)!
    else:
        pass
    if kind == 'E':
        if p != none:
            bad += 1
            print('ACCEPT `%{src}`: LPeg says %{c['err'].as_str().?}')
        continue
    if p == none:
        -- LPeg does not check a rule that the first rule never reaches (`strict` is false when LPeg rejects the
        -- grammar once every rule is reached), and it drops a choice after one that can not fail before it looks
        -- for left recursion. Inside `p^0`, LPeg does not see a repetition that is empty through a rule.
        if !c['strict'].as_bool().? or diag.msg.index('is left recursive') != none or src.index('^0') != none:
            stricter += 1
        else:
            bad += 1
            print('REJECT `%{src}`: %{diag.msg}')
        continue
    if kind == 'R':
        -- A back reference to a capture that is not there, or a `%2` without a second capture: LPeg raises an
        -- error, the module fails the match or gives nothing.
        skipped += 1
        continue
    if src.index('{}') != none and src.index('->') != none:
        -- The value of a position capture is a number in LPeg and has no text here, which shows in `%1`.
        skipped += 1
        continue
    all := c['all'].as_str().?
    if all != '!':
        got_all := show_all(&p.?, hay)
        if got_all != all:
            bad += 1
            print('DIFF find_all `%{src}` on `%{hay}`: got %{got_all}, LPeg %{all}')
    m := p.?.match(hay)
    if kind == 'N':
        if m != none:
            bad += 1
            print('DIFF `%{src}` on `%{hay}`: got a match to %{m.?.end}, LPeg none')
        continue
    if m == none:
        bad += 1
        print('DIFF `%{src}` on `%{hay}`: got none, LPeg a match to %{c['end'].as_int().?}')
        continue
    got := '%{m.?.end}'
    var vals []str = {}
    root := m.?
    values(hay, &root, &vals)
    for vals |v|:
        got += '|' + v
    want := '%{c['end'].as_int().?}'
    for c['caps'].as_array().? |v|:
        want += '|' + bytes_str(v)
    if got != want:
        bad += 1
        print('DIFF `%{src}` on `%{hay}`: got %{got}, LPeg %{want}')
print('%{count} cases, %{bad} differ, %{stricter} rejected only here, %{skipped} skipped')
