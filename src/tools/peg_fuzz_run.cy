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

doc := json.parse(os.read_file_str(os.args()[1])!)!
count := 0
bad := 0
skipped := 0
stricter := 0
for doc.as_array().? |c|:
    src := c['peg'].as_str().?
    hay := c['hay'].as_str().?
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
        want += '|' + v.as_str().?
    if got != want:
        bad += 1
        print('DIFF `%{src}` on `%{hay}`: got %{got}, LPeg %{want}')
print('%{count} cases, %{bad} differ, %{stricter} rejected only here, %{skipped} skipped')
