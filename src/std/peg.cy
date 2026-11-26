--| Parsing expression grammars: patterns with rules that call each other, for input that a regular expression
--| can not describe, such as nested brackets. The syntax is that of the `re` module of LPeg, and `'text'i` matches
--| the text in any case.
--| A choice `a / b` is ordered: when `a` matches, `b` is not tried. Repetitions take all they can and do not give back.
--| Matching is by Unicode code point, offsets are in bytes.
--| A grammar backtracks, so there is no bound on the time of a match as there is for `regex`.
--| Sample usage:
--| ```cy
--| use peg
--|
--| p := peg.compile("""
--|     list  <- '(' item (',' item)* ')'
--|     item  <- list / {:num: %d+ :}
--| """)!
--| c := p.parse('(1,(22,3),4)')!
--| for c.all('num') |n|:
--|     print(n.text)                 --> 1, 22, 3, 4
--|
--| kv := peg.compile(`{:key: %w+ :} '=' {:val: %d+ :}`)!
--| print(kv.find('a retries=3').?['val'])        --> 3
--| print(kv.replace_all('a=1 b=2', '$val:$key'))  --> 1:a 2:b
--|
--| var diag peg.Diag = {}
--| try:
--|     _ = p.parse('(1,)', &&diag)!
--| else |err|:
--|     print(diag.msg)   --> Expected `'('` or `%d` at line 1, column 4, found `)`.
--| ```

--| Compiling stops with `error.TooBig` when the program of a grammar has more instructions than this.
--| A counted repetition is expanded: `p^100` takes 100 times the instructions of `p`.
const MaxInsts = 65536

--| Compiling stops with `error.Syntax` when the expressions of a grammar nest deeper than this.
const MaxDepth = 250

--| A match stops when it has more open rule calls and choices than this: `parse` returns `error.TooDeep`,
--| the other functions panic.
const MaxStack = 100000

--| A match stops when it has more captures than this: `parse` returns `error.TooBig`, the other functions panic.
const MaxCaptures = 1000000

--| Where and why compiling or `parse` failed. `pos` is a byte offset into the grammar or the input.
--| `line` and `col` start at 1, `col` counts bytes.
--| After `parse`, `expected` has what the grammar could have matched at `pos`, as written in the grammar.
type Diag:
    msg      str = ''
    pos      int = 0
    line     int = 0
    col      int = 0
    expected []str = {}

--| A capture: the bytes `start..end` of the input, and the captures inside it.
--| The capture that a match returns is the whole match and has no name.
--| `text` is the input text, except for a string capture `p -> '..'` and a substitution capture `{~ p ~}`.
type Capture:
    name  str
    start int
    end   int
    text  str
    kids  []Capture

--| A compiled grammar. It does not change and can be used for any number of matches.
type Peg:
    -prog    []int
    -names   []str
    -strs    []str
    -exp_pc  []int
    -exp_txt []str
    -src     str

-- Program layout, shared with `peg.zig`. A program is one `[]int`:
--   header (8 words): magic, instruction count, instruction offset, 0...
--   literals: the bytes of the literals, one byte a word, and the code points of a case-insensitive one
--   sets: `ascii_lo, ascii_hi, negated, nranges`, then `nranges` pairs `lo, hi`
--   instructions: three words each, `op, a, b`
const Magic = 0x50450001
const HeaderLen = 8

const OpEnd = 0
const OpAny = 1
const OpStr = 2            -- a: offset of the bytes, b: length
const OpSet = 3            -- a: offset of the set
const OpSpan = 4           -- a: offset of the set
const OpChoice = 5         -- a: target, b: 1 for a predicate
const OpCommit = 6         -- a: target
const OpPartialCommit = 7  -- a: target
const OpBackCommit = 8     -- a: target
const OpFail = 9
const OpFailTwice = 10
const OpCall = 11          -- a: target
const OpRet = 12
const OpJmp = 13           -- a: target
const OpOpen = 14          -- a: capture kind, b: name or string
const OpClose = 15
const OpBackref = 16       -- a: name
const OpStrFold = 17       -- a: offset of the code points, b: count

-- Capture kinds, in the program and in the capture log. 0 in the log closes a capture.
const CapSimple = 1
const CapNamed = 2
const CapSubst = 3
const CapString = 4
const CapPos = 5

-- `exec` modes and results.
const ModeSearch = 1
const ModeTrack = 2
const OutLen = 25
const OutStart = 0
const OutEnd = 1
const OutCaps = 2
const OutFar = 3
const OutFails = 4
const OutPcs = 5
const OutRes = 24
const ResMatch = 1
const ResNone = 0
const ResStack = -1
const ResCaps = -2
const ResInterrupt = -4

-- Node kinds.
const NEmpty = 0
const NStr = 1       -- a: offset in `lits`, b: length, c: 1 when it ignores case (`lits` has code points)
const NAny = 2
const NSet = 3       -- a: offset in `sets`
const NSeq = 4       -- a: first child in `kids`, b: count
const NAlt = 5       -- a: first child in `kids`, b: count
const NRep = 6       -- a: child, b: min, c: max or -1
const NAnd = 7       -- a: child
const NNot = 8       -- a: child
const NCall = 9      -- a: index in `calls`, then the rule
const NCap = 10      -- a: child or -1, b: capture kind, c: name or string
const NBackref = 11  -- a: name

-type Node:
    kind  int
    a     int = 0
    b     int = 0
    c     int = 0
    -- The bytes of the grammar that this node was parsed from.
    from  int = 0
    to    int = 0
    depth int = 0

#[bind]
-fn exec(prog [&]int, hay str, start int, mode int, out [&]int, caps [&]int, buffer_t int) -> []int

-- The length of the unit of input at byte `i` as the matcher counts it, 1 at the end so that a search moves on.
#[bind]
-fn unit_len(hay str, i int) -> int

--| Compiles a grammar. Returns `error.Syntax` for a grammar that is malformed, calls a rule that is not defined,
--| is left recursive or repeats something that can match nothing, and `error.TooBig` for one that is over `MaxInsts`.
fn compile(grammar str) -> !Peg:
    var diag Diag = {}
    return compile(grammar, &&diag)

--| Compiles a grammar. On failure, `diag` tells where and why.
fn compile(grammar str, diag &&Diag) -> !Peg:
    diag.* = Diag{}
    if !str.is_utf8(grammar.span()):
        diag.msg = 'The grammar is not valid UTF-8.'
        return error.Syntax
    b := Builder{src=grammar}
    b.build() !else |err|:
        diag.msg = b.msg
        diag.pos = b.err_pos
        set_line_col(diag, grammar)
        return err
    return Peg{prog=b.assemble(), names=b.names, strs=b.strs, exp_pc=b.exp_pc, exp_txt=b.exp_txt, src=grammar}

-fn set_line_col(diag &&Diag, s str):
    line := 1
    last := 0
    for 0..diag.pos |i|:
        if s[i] == '\n':
            line += 1
            last = i + 1
    diag.line = line
    diag.col = diag.pos - last + 1

--| Returns the grammar that this was compiled from.
fn (&Peg) source() -> str:
    return self.src

-type Run:
    out  []int
    caps []int

-fn new_run() -> Run:
    return Run{out=[]int(OutLen, 0), caps=[]int(192, 0)}

-- Runs the program. A capture log that does not fit in `r.caps` comes back in a bigger slice, which is kept.
-fn (&Peg) run(s str, start int, mode int, r &&Run) -> int:
    while:
        grown := exec(self.prog.span(), s, start, mode, r.out.span(), r.caps.span(), type.id(RawBuffer[byte]))
        if grown.len() > 0:
            r.caps = grown
        res := r.out[OutRes]
        if res != ResInterrupt:
            return res
        -- The host asked the VM to stop: the checkpoint of this loop stops it before the match runs again.

-fn check(res int) -> bool:
    if res == ResStack:
        panic('The match has more than %{MaxStack} open rule calls and choices. `parse` returns this as `error.TooDeep`.')
    if res == ResCaps:
        panic('The match has more than %{MaxCaptures} captures. `parse` returns this as `error.TooBig`.')
    return res == ResMatch

--| Matches at the start of `s`. The match does not have to reach the end of `s`.
fn (&Peg) match(s str) -> ?Capture:
    return self.match(s, 0)

--| Matches at byte `start` of `s`.
fn (&Peg) match(s str, start int) -> ?Capture:
    if start < 0 or start > s.len():
        return none
    r := new_run()
    if !check(self.run(s, start, 0, &&r)):
        return none
    return self.tree(s, &r)

--| Matches all of `s`. Returns `error.NoMatch` when the grammar does not match or stops before the end,
--| `error.TooDeep` when the match is over `MaxStack` and `error.TooBig` when it is over `MaxCaptures`.
fn (&Peg) parse(s str) -> !Capture:
    var diag Diag = {}
    return self.parse(s, &&diag)

--| Matches all of `s`. On failure, `diag` tells the farthest place that the match reached and what the grammar
--| expected there.
fn (&Peg) parse(s str, diag &&Diag) -> !Capture:
    diag.* = Diag{}
    r := new_run()
    res := self.run(s, 0, ModeTrack, &&r)
    if res == ResStack:
        diag.msg = 'The match has more than %{MaxStack} open rule calls and choices.'
        return error.TooDeep
    if res == ResCaps:
        diag.msg = 'The match has more than %{MaxCaptures} captures.'
        return error.TooBig
    if res == ResMatch and r.out[OutEnd] == s.len():
        return self.tree(s, &r)
    var expected []str = {}
    pos := r.out[OutFar]
    nfails := r.out[OutFails]
    if res == ResMatch:
        -- The grammar matched and stopped before the end.
        if nfails == 0 or pos < r.out[OutEnd]:
            pos = r.out[OutEnd]
            nfails = 0
        if pos == r.out[OutEnd]:
            expected.append('the end of the input')
    for 0..nfails |i|:
        txt := self.expect_of(r.out[OutPcs + i])
        if txt.len() > 0 and !has_str(expected, txt):
            expected.append(txt)
    diag.pos = pos
    diag.expected = expected
    set_line_col(diag, s)
    msg := 'Expected '
    if expected.len() == 0:
        msg = 'No match '
    for 0..expected.len() |i|:
        if i > 0:
            if i == expected.len() - 1:
                msg += ' or '
            else:
                msg += ', '
        msg += show_expected(expected[i])
    if expected.len() > 0:
        msg += ' '
    found := 'the end of the input'
    if pos < s.len():
        found = show_found(s, pos)
    diag.msg = msg + 'at line %{diag.line}, column %{diag.col}, found %{found}.'
    return error.NoMatch

-fn has_str(list []str, s str) -> bool:
    for list |e|:
        if e == s:
            return true
    return false

-fn show_expected(txt str) -> str:
    if txt.starts_with('the ') or txt.starts_with('any ') or txt.starts_with('not '):
        return txt
    return '`' + txt + '`'

-fn show_found(s str, pos int) -> str:
    c := int(s[pos])
    if c == '\n':
        return 'a line feed'
    if c < 32 or c == 127:
        return 'the control character %{c}'
    n := unit_len(s, pos)
    if !str.is_utf8(s[pos..pos + n].span()):
        return 'the byte %{c}'
    return '`' + s[pos..pos + n] + '`'

-fn (&Peg) expect_of(pc int) -> str:
    for 0..self.exp_pc.len() |i|:
        if self.exp_pc[i] == pc:
            return self.exp_txt[i]
    return ''

--| Returns the leftmost match in `s`: the first place where the grammar matches.
fn (&Peg) find(s str) -> ?Capture:
    return self.find(s, 0)

--| Returns the leftmost match that starts at byte `start` or later.
fn (&Peg) find(s str, start int) -> ?Capture:
    if start < 0 or start > s.len():
        return none
    r := new_run()
    if !check(self.run(s, start, ModeSearch, &&r)):
        return none
    return self.tree(s, &r)

--| Returns every match in `s` from left to right. The matches do not overlap. An empty match that touches the end
--| of the match before it is left out.
fn (&Peg) find_all(s str) -> []Capture:
    var ranges []int = {}
    var res []Capture = {}
    self.scan(s, &&ranges, &&res, true)
    return res

-- Finds the matches of `find_all`: the start and the end of each in `ranges`, and its tree in `trees` when
-- `want_trees`. The trees are left out when only the places are needed, as they cost a string for each capture.
-fn (&Peg) scan(s str, ranges &&[]int, trees &&[]Capture, want_trees bool):
    r := new_run()
    at := 0
    last_end := -1
    while at <= s.len():
        if !check(self.run(s, at, ModeSearch, &&r)):
            break
        start := r.out[OutStart]
        end := r.out[OutEnd]
        if start == end:
            if end == last_end:
                at = end + unit_len(s, end)
                continue
            at = end + unit_len(s, end)
        else:
            at = end
        last_end = end
        ranges.append(start)
        ranges.append(end)
        if want_trees:
            trees.append(self.tree(s, &r))

--| Returns `s` with the leftmost match replaced by `repl`, see `replace_all`.
fn (&Peg) replace(s str, repl str) -> str:
    if self.find(s) |c|:
        return s[0..c.start] + c.expand(repl) + s[c.end..]
    return s

--| Returns `s` with every match replaced by `repl`.
--| In `repl`, `$0` stands for the match, `$1` and `${1}` for its first capture, `$name` and `${name}` for the first
--| capture with that name, and `$$` for a `$`. A capture that does not exist gives nothing.
fn (&Peg) replace_all(s str, repl str) -> str:
    plain := repl.index('$') == none
    var ranges []int = {}
    var trees []Capture = {}
    self.scan(s, &&ranges, &&trees, !plain)
    var buf []byte = {}
    last := 0
    for 0..ranges.len() / 2 |i|:
        buf.append(s[last..ranges[i * 2]].span())
        if plain:
            buf.append(repl.span())
        else:
            buf.append(trees[i].expand(repl).span())
        last = ranges[i * 2 + 1]
    buf.append(s[last..].span())
    return str(buf)

--| Returns `s` with the leftmost match replaced by what `repl` returns for it, see `replace_all`.
fn (&Peg) replace(s str, repl &OpaqueFunc[fn(&Capture) -> str]) -> str:
    if self.find(s) |c|:
        return s[0..c.start] + repl.*(&c) + s[c.end..]
    return s

--| Returns `s` with every match replaced by what `repl` returns for it: the capture of the whole match, with the
--| captures inside it. The text that `repl` returns is taken as it is: `$` has no meaning in it. `repl` is called
--| once for each match, from left to right.
fn (&Peg) replace_all(s str, repl &OpaqueFunc[fn(&Capture) -> str]) -> str:
    var ranges []int = {}
    var trees []Capture = {}
    self.scan(s, &&ranges, &&trees, true)
    var buf []byte = {}
    last := 0
    for 0..ranges.len() / 2 |i|:
        buf.append(s[last..ranges[i * 2]].span())
        buf.append(repl.*(&trees[i]).span())
        last = ranges[i * 2 + 1]
    buf.append(s[last..].span())
    return str(buf)

--| Returns the pieces of `s` between the matches.
fn (&Peg) split(s str) -> []str:
    var ranges []int = {}
    var trees []Capture = {}
    self.scan(s, &&ranges, &&trees, false)
    var res []str = {}
    last := 0
    for 0..ranges.len() / 2 |i|:
        res.append(s[last..ranges[i * 2]])
        last = ranges[i * 2 + 1]
    res.append(s[last..])
    return res

-- Builds the tree of captures from the log of a match.
-fn (&Peg) tree(s str, r &Run) -> Capture:
    start := r.out[OutStart]
    end := r.out[OutEnd]
    var stack []Capture = {Capture{name='', start=start, end=end, text=s[start..end], kids={}}}
    var kinds []int = {0}
    var auxs []int = {0}
    sp := 1
    n := r.out[OutCaps]
    for 0..n |i|:
        kind := r.caps[i * 3]
        pos := r.caps[i * 3 + 2]
        if kind != 0:
            c := Capture{name='', start=pos, end=pos, text='', kids={}}
            if kind == CapNamed:
                c.name = self.names[r.caps[i * 3 + 1]]
            if sp < stack.len():
                stack[sp] = c
                kinds[sp] = kind
                auxs[sp] = r.caps[i * 3 + 1]
            else:
                stack.append(c)
                kinds.append(kind)
                auxs.append(r.caps[i * 3 + 1])
            sp += 1
            continue
        sp -= 1
        c := stack[sp]
        c.end = pos
        switch kinds[sp]:
            case CapSubst:
                c.text = subst_text(s, &c)
            case CapString:
                c.text = string_text(s, &c, self.strs[auxs[sp]])
            else:
                c.text = s[c.start..c.end]
        stack[sp - 1].kids.append(c)
    return stack[0]

-fn subst_text(s str, c &Capture) -> str:
    var buf []byte = {}
    last := c.start
    for c.kids |k|:
        buf.append(s[last..k.start].span())
        buf.append(k.text.span())
        last = k.end
    buf.append(s[last..c.end].span())
    return str(buf)

-fn string_text(s str, c &Capture, tmpl str) -> str:
    if tmpl.index('%') == none:
        return tmpl
    res := ''
    i := 0
    last := 0
    n := tmpl.len()
    while i < n:
        if tmpl[i] != '%' or i + 1 >= n:
            i += 1
            continue
        res += tmpl[last..i]
        d := int(tmpl[i + 1])
        if d == '0':
            res += s[c.start..c.end]
        else d >= '1' and d <= '9':
            if d - '1' < c.kids.len():
                res += c.kids[d - '1'].text
        else:
            -- `%%`, checked when the grammar was compiled.
            res += '%'
        i += 2
        last = i
    return res + tmpl[last..]

--| Returns the number of captures directly inside this one.
fn (&Capture) len() -> int:
    return self.kids.len()

--| Returns the text of the capture at `i` among the captures directly inside this one. Panics when there is none.
fn (&Capture) @index(i int) -> str:
    if i < 0 or i >= self.kids.len():
        panic('Capture %{i} does not exist. This capture has %{self.kids.len()} inside it.')
    return self.kids[i].text

--| Returns the text of the first capture named `name` inside this one, at any depth, or `''` when there is none.
fn (&Capture) @index(name str) -> str:
    if self.get(name) |c|:
        return c.text
    return ''

--| Returns the first capture named `name` inside this one, at any depth, in the order of the input.
fn (&Capture) get(name str) -> ?Capture:
    for self.kids |k|:
        if k.name == name:
            return k
        if k.get(name) |c|:
            return c
    return none

--| Returns every capture named `name` inside this one, at any depth, in the order of the input.
fn (&Capture) all(name str) -> []Capture:
    var res []Capture = {}
    self.collect(name, &&res)
    return res

-fn (&Capture) collect(name str, res &&[]Capture):
    for self.kids |k|:
        if k.name == name:
            res.append(k)
        k.collect(name, res)

--| Returns `repl` with its capture references replaced, see `Peg.replace_all`.
fn (&Capture) expand(repl str) -> str:
    res := ''
    i := 0
    last := 0
    n := repl.len()
    while i < n:
        if repl[i] != '$':
            i += 1
            continue
        res += repl[last..i]
        if i + 1 < n and repl[i + 1] == '$':
            res += '$'
            i += 2
            last = i
            continue
        -- The end of the reference and of its name.
        var ref_end int = i
        var name str = ''
        if i + 1 < n and repl[i + 1] == '{':
            if repl[i + 2..].index('}') |close|:
                name = repl[i + 2..i + 2 + close]
                ref_end = i + 3 + close
        else:
            j := i + 1
            while j < n and is_name_char(int(repl[j])):
                j += 1
            name = repl[i + 1..j]
            ref_end = j
        if ref_end == i or name.len() == 0:
            -- Not a reference: the `$` stands for itself.
            res += '$'
            i += 1
            last = i
            continue
        if ref_number(name) |num|:
            if num == 0:
                res += self.text
            else num <= self.kids.len():
                res += self.kids[num - 1].text
        else:
            if self.get(name) |c|:
                res += c.text
        i = ref_end
        last = i
    return res + repl[last..]

-fn ref_number(name str) -> ?int:
    if name.len() > 9:
        return none
    n := 0
    for 0..name.len() |i|:
        c := int(name[i])
        if c < '0' or c > '9':
            return none
        n = n * 10 + (c - '0')
    return n

-fn is_alpha(c int) -> bool:
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')

-fn is_digit(c int) -> bool:
    return c >= '0' and c <= '9'

-fn is_name_start(c int) -> bool:
    return is_alpha(c) or c == '_'

-fn is_name_char(c int) -> bool:
    return is_alpha(c) or is_digit(c) or c == '_'

-fn is_hex(c int) -> bool:
    return is_digit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')

-fn hex_val(c int) -> int:
    if c <= '9':
        return c - '0'
    if c >= 'a':
        return c - 'a' + 10
    return c - 'A' + 10

-fn rune_len(cp int) -> int:
    if cp < 0x80:
        return 1
    if cp < 0x800:
        return 2
    if cp < 0x10000:
        return 3
    return 4

--| Shows a character of a grammar in a message.
-fn show(cp int) -> str:
    if cp < 0:
        return 'the end of the grammar'
    if cp == '\n':
        return 'a line feed'
    if cp < 32 or cp == 127:
        return 'the control character %{cp}'
    return '`' + str.init_rune(cp) + '`'

-- The ranges of a `%x` class as pairs, or an empty list for a letter that is no class.
-fn class_ranges(c int) -> []int:
    switch c:
        case 'a':
            return {65, 90, 97, 122}
        case 'c':
            return {0, 31, 127, 127}
        case 'd':
            return {48, 57}
        case 'g':
            return {33, 126}
        case 'l':
            return {97, 122}
        case 'p':
            return {33, 47, 58, 64, 91, 96, 123, 126}
        case 's':
            return {9, 13, 32, 32}
        case 'u':
            return {65, 90}
        case 'w':
            return {48, 57, 65, 90, 97, 122}
        case 'x':
            return {48, 57, 65, 70, 97, 102}
        else:
            return {}

-- Returns the ranges that `ranges` leaves out, over all code points.
-fn complement(ranges []int) -> []int:
    -- Sort the pairs by their start.
    r := ranges
    n := r.len() / 2
    for 1..n |i|:
        lo := r[i * 2]
        hi := r[i * 2 + 1]
        j := i
        while j > 0 and r[(j - 1) * 2] > lo:
            r[j * 2] = r[(j - 1) * 2]
            r[j * 2 + 1] = r[(j - 1) * 2 + 1]
            j -= 1
        r[j * 2] = lo
        r[j * 2 + 1] = hi
    var res []int = {}
    next := 0
    for 0..n |i|:
        if r[i * 2] > next:
            res.append(next)
            res.append(r[i * 2] - 1)
        if r[i * 2 + 1] + 1 > next:
            next = r[i * 2 + 1] + 1
    if next <= 0x10ffff:
        res.append(next)
        res.append(0x10ffff)
    return res

-- The parser, the checks and the code generator. The grammar becomes nodes, the nodes become instructions.
-type Builder:
    src     str
    pos     int = 0
    msg     str = ''
    err_pos int = 0
    depth   int = 0
    nodes   []Node = {}
    kids    []int = {}
    lits    []int = {}
    sets    []int = {}
    names   []str = {}
    strs    []str = {}
    -- The names of the rules that are called, by call.
    calls   []str = {}
    rules   []str = {}
    roots   []int = {}
    rule_at []int = {}
    nulls   []bool = {}
    insts   []int = {}
    exp_pc  []int = {}
    exp_txt []str = {}
    -- The instructions that call a rule, to patch.
    fixes   []int = {}
    -- Nodes visited by `gen`, to stop a grammar that repeats nothing a great many times.
    work    int = 0
    -- Set by `parse_percent` for a class such as `%D` outside brackets.
    negated bool = false

fn (&&Builder) fail(msg str) -> error:
    self.msg = msg
    self.err_pos = self.pos
    return error.Syntax

fn (&&Builder) fail_at(pos int, msg str) -> error:
    self.msg = msg
    self.err_pos = pos
    return error.Syntax

fn (&Builder) peek() -> int:
    if self.pos < self.src.len():
        return int(self.src[self.pos])
    return -1

fn (&Builder) peek_at(off int) -> int:
    if self.pos + off < self.src.len():
        return int(self.src[self.pos + off])
    return -1

-- Reads the code point at `pos`.
fn (&Builder) rune() -> int:
    cp := int(self.src.rune_at(self.pos))
    self.pos += rune_len(cp)
    return cp

-- Skips white space and the comments `-- ..` and `# ..`.
fn (&Builder) skip():
    while self.pos < self.src.len():
        c := self.src[self.pos]
        if c == ' ' or c == '\t' or c == '\n' or c == '\r':
            self.pos += 1
        else c == '#' or (c == '-' and self.peek_at(1) == '-'):
            while self.pos < self.src.len() and self.src[self.pos] != '\n':
                self.pos += 1
        else:
            return

fn (&&Builder) add(node Node) -> !int:
    if node.depth > MaxDepth:
        return self.fail_at(node.from, 'The grammar nests deeper than %{MaxDepth} levels.')
    self.nodes.append(node)
    return self.nodes.len() - 1

fn (&&Builder) enter() -> !void:
    self.depth += 1
    if self.depth > MaxDepth:
        return self.fail('The grammar nests deeper than %{MaxDepth} levels.')

fn (&&Builder) name_id(name str) -> int:
    for 0..self.names.len() |i|:
        if self.names[i] == name:
            return i
    self.names.append(name)
    return self.names.len() - 1

-- Reads a name at `pos`, or returns `''`.
fn (&Builder) read_name() -> str:
    start := self.pos
    if !is_name_start(self.peek()):
        return ''
    while is_name_char(self.peek()):
        self.pos += 1
    return self.src[start..self.pos]

-- Whether a rule `name <-` starts at `pos`.
fn (&Builder) at_rule() -> bool:
    save := self.pos
    name := self.read_name()
    self.skip()
    res := name.len() > 0 and self.peek() == '<' and self.peek_at(1) == '-'
    self.pos = save
    return res

fn (&&Builder) build() -> !void:
    self.skip()
    if self.at_rule():
        while self.pos < self.src.len():
            if !self.at_rule():
                break
            at := self.pos
            name := self.read_name()
            for 0..self.rules.len() |i|:
                if self.rules[i] == name:
                    return self.fail_at(at, 'The rule `%{name}` is defined twice.')
            self.skip()
            self.pos += 2
            self.rules.append(name)
            self.rule_at.append(at)
            -- The place of the root is kept before the rule is parsed, for the order of the rules.
            self.roots.append(-1)
            idx := self.roots.len() - 1
            self.roots[idx] = self.parse_alt()!
            self.skip()
    else:
        root := self.parse_alt()!
        self.roots.append(root)
    self.skip()
    if self.pos < self.src.len():
        c := self.peek()
        if c == ')':
            return self.fail('This `)` closes no group. Write `\')\'` to match a parenthesis.')
        if c == '}':
            return self.fail('This `}` closes no capture. Write `\'}\'` to match a brace.')
        return self.fail('Unexpected %{show(c)}.')
    self.resolve()!
    self.check()!
    self.gen_all()!

-- alt := seq ('/' seq)*
fn (&&Builder) parse_alt() -> !int:
    self.enter()!
    from := self.pos
    var branches []int = {}
    branches.append(self.parse_seq()!)
    while:
        self.skip()
        if self.peek() != '/':
            break
        self.pos += 1
        branches.append(self.parse_seq()!)
    self.depth -= 1
    if branches.len() == 1:
        return branches[0]
    return self.join(NAlt, branches, from)

fn (&&Builder) join(kind int, items []int, from int) -> !int:
    start := self.kids.len()
    depth := 0
    for items |n|:
        self.kids.append(n)
        if self.nodes[n].depth > depth:
            depth = self.nodes[n].depth
    return self.add(Node{kind=kind, a=start, b=items.len(), from=from, to=self.pos, depth=depth + 1})

fn (&&Builder) parse_seq() -> !int:
    self.skip()
    from := self.pos
    var items []int = {}
    while:
        self.skip()
        c := self.peek()
        if c == -1 or c == '/' or c == ')' or c == '}':
            break
        if (c == ':' or c == '~') and self.peek_at(1) == '}':
            break
        if is_name_start(c) and self.at_rule():
            break
        items.append(self.parse_prefix()!)
    if items.len() == 0:
        return self.add(Node{kind=NEmpty, from=from, to=from})
    if items.len() == 1:
        return items[0]
    return self.join(NSeq, items, from)

fn (&&Builder) parse_prefix() -> !int:
    c := self.peek()
    if c != '&' and c != '!':
        return self.parse_suffix()
    from := self.pos
    self.enter()!
    self.pos += 1
    self.skip()
    n := self.peek()
    if n == -1 or n == '/' or n == ')' or n == '}':
        return self.fail('Expected a pattern after `%{str.init_rune(c)}`, found %{show(n)}.')
    child := self.parse_prefix()!
    self.depth -= 1
    kind := NAnd
    if c == '!':
        kind = NNot
    return self.add(Node{kind=kind, a=child, from=from, to=self.pos, depth=self.nodes[child].depth + 1})

fn (&&Builder) parse_number(what str) -> !int:
    start := self.pos
    n := 0
    while is_digit(self.peek()):
        if n <= MaxInsts:
            n = n * 10 + (self.peek() - '0')
        self.pos += 1
    if self.pos == start:
        return self.fail('Expected a number after `%{what}`, found %{show(self.peek())}.')
    if n > MaxInsts:
        self.pos = start
        self.msg = 'The repetition count is over the limit of %{MaxInsts}.'
        self.err_pos = start
        return error.TooBig
    return n

fn (&&Builder) rep(child int, min int, max int, from int) -> !int:
    return self.add(Node{kind=NRep, a=child, b=min, c=max, from=from, to=self.pos, depth=self.nodes[child].depth + 1})

fn (&&Builder) parse_suffix() -> !int:
    from := self.pos
    node := self.parse_primary()!
    while:
        self.skip()
        c := self.peek()
        if c == '*':
            self.pos += 1
            node = self.rep(node, 0, -1, from)!
        else c == '+':
            self.pos += 1
            node = self.rep(node, 1, -1, from)!
        else c == '?':
            self.pos += 1
            node = self.rep(node, 0, 1, from)!
        else c == '^':
            self.pos += 1
            sign := self.peek()
            if sign == '+' or sign == '-':
                self.pos += 1
            n := self.parse_number('^')!
            if sign == '+':
                node = self.rep(node, n, -1, from)!
            else sign == '-':
                node = self.rep(node, 0, n, from)!
            else:
                node = self.rep(node, n, n, from)!
        else c == '-' and self.peek_at(1) == '>':
            at := self.pos
            self.pos += 2
            self.skip()
            q := self.peek()
            if q != '\'' and q != '"':
                return self.fail_at(at, 'Only a string can follow `->`, as in `p -> \'text %1\'`. Functions, tables and capture numbers are not supported.')
            tmpl := self.parse_template()!
            self.strs.append(tmpl)
            node = self.add(Node{kind=NCap, a=node, b=CapString, c=self.strs.len() - 1, from=from, to=self.pos,
                depth=self.nodes[node].depth + 1})!
        else (c == '=' or c == '~') and self.peek_at(1) == '>':
            return self.fail('`%{str.init_rune(c)}>` calls a function, which is not supported. Check the capture after the match instead.')
        else c == '>' and self.peek_at(1) == '>':
            return self.fail('`>>` calls a function, which is not supported. Check the captures after the match instead.')
        else c == '{' and is_digit(self.peek_at(1)):
            return self.fail('A counted repetition is `p^3` (exactly), `p^+3` (at least) or `p^-3` (at most), not `p{3}`.')
        else:
            break
    return node

-- Reads the string after `->` and checks its `%` references.
fn (&&Builder) parse_template() -> !str:
    at := self.pos
    lit := self.parse_literal()!
    var buf []byte = {}
    for 0..lit.b |i|:
        buf.append(byte(self.lits[lit.a + i]))
    self.lits = self.lits[0..lit.a]
    tmpl := str(buf)
    i := 0
    while i < tmpl.len():
        if tmpl[i] == '%':
            d := -1
            if i + 1 < tmpl.len():
                d = int(tmpl[i + 1])
            if d != '%' and !is_digit(d):
                return self.fail_at(at, 'In the string after `->`, `%` is followed by a digit (`%0` is the match, `%1` the first capture) or is written `%%`.')
            i += 1
        i += 1
    return tmpl

-type Lit:
    a int
    b int

-- Reads an escape after `\` in a literal or a class and returns its code point.
fn (&&Builder) parse_escape() -> !int:
    at := self.pos - 1
    c := self.peek()
    if c == -1:
        return self.fail_at(at, 'The grammar ends after `\\`.')
    switch c:
        case 'n':
            self.pos += 1
            return 10
        case 'r':
            self.pos += 1
            return 13
        case 't':
            self.pos += 1
            return 9
        case '\\', '\'', '"', '[', ']', '-', '^', '%':
            self.pos += 1
            return c
        case 'x':
            if !is_hex(self.peek_at(1)) or !is_hex(self.peek_at(2)):
                return self.fail_at(at, '`\\x` takes two hex digits, as in `\\x7F`.')
            v := hex_val(self.peek_at(1)) * 16 + hex_val(self.peek_at(2))
            if v > 127:
                return self.fail_at(at, '`\\x` is for the code points up to `\\x7F`. Write `\\u{%{self.src[self.pos + 1..self.pos + 3]}}` for the code point.')
            self.pos += 3
            return v
        case 'u':
            if self.peek_at(1) != '{':
                return self.fail_at(at, '`\\u` takes a code point in braces, as in `\\u{1F600}`.')
            self.pos += 2
            v := 0
            digits := 0
            while is_hex(self.peek()):
                if digits < 8:
                    v = v * 16 + hex_val(self.peek())
                digits += 1
                self.pos += 1
            if digits == 0 or digits > 6 or self.peek() != '}':
                return self.fail_at(at, '`\\u` takes one to six hex digits in braces, as in `\\u{1F600}`.')
            self.pos += 1
            if v > 0x10ffff or (v >= 0xd800 and v <= 0xdfff):
                return self.fail_at(at, 'This is not a Unicode code point.')
            return v
        else:
            cp := self.rune()
            self.pos = at + 1
            return self.fail_at(at, 'Unknown escape `\\%{str.init_rune(cp)}`. The escapes are `\\n \\r \\t \\\\ \\\' \\" \\[ \\] \\- \\^ \\xHH \\u{H..}`.')

-- Reads a literal in quotes into `lits`.
fn (&&Builder) parse_literal() -> !Lit:
    open := self.pos
    quote := self.peek()
    self.pos += 1
    start := self.lits.len()
    while:
        c := self.peek()
        if c == -1:
            return self.fail_at(open, 'This string is not closed.')
        if c == quote:
            self.pos += 1
            break
        if c == '\\':
            self.pos += 1
            cp := self.parse_escape()!
            enc := str.init_rune(cp)
            for 0..enc.len() |i|:
                self.lits.append(int(enc[i]))
            continue
        self.lits.append(c)
        self.pos += 1
    return Lit{a=start, b=self.lits.len() - start}

-- Turns the bytes of `lit`, the last literal in `lits`, into code points, for a literal `'..'i` that ignores case.
fn (&&Builder) fold_literal(lit Lit, from int) -> !int:
    var buf []byte = {}
    for 0..lit.b |i|:
        buf.append(byte(self.lits[lit.a + i]))
    text := str(buf)
    self.lits = self.lits[0..lit.a]
    i := 0
    while i < text.len():
        cp := int(text.rune_at(i))
        self.lits.append(cp)
        i += rune_len(cp)
    return self.add(Node{kind=NStr, a=lit.a, b=self.lits.len() - lit.a, c=1, from=from, to=self.pos})

-- Adds a set of code point ranges to `sets` and returns its node.
fn (&&Builder) set_node(ranges []int, negated bool, from int) -> !int:
    off := self.sets.len()
    lo := 0
    hi := 0
    n := ranges.len() / 2
    for 0..n |i|:
        a := ranges[i * 2]
        z := ranges[i * 2 + 1]
        if z > 127:
            z = 127
        while a <= z:
            if a < 64:
                lo = lo || (1 << a)
            else:
                hi = hi || (1 << (a - 64))
            a += 1
    neg := 0
    if negated:
        neg = 1
    self.sets.append(lo)
    self.sets.append(hi)
    self.sets.append(neg)
    self.sets.append(n)
    for ranges |v|:
        self.sets.append(v)
    return self.add(Node{kind=NSet, a=off, from=from, to=self.pos})

-- Reads the letter of a `%x` class after the `%` and returns its ranges.
fn (&&Builder) parse_percent(in_class bool) -> ![]int:
    at := self.pos - 1
    c := self.peek()
    if c == '{':
        return self.fail_at(at, 'Error labels (`%` and a name in braces) are not supported.')
    name := self.read_name()
    if name == 'nl' and !in_class:
        return {10, 10}
    if name.len() == 1:
        lower := int(str.ascii_lower(name[0]))
        ranges := class_ranges(lower)
        if ranges.len() > 0:
            if lower != int(name[0]):
                if in_class:
                    return complement(ranges)
                -- Outside a class, the opposite is a negated set, which also takes a byte that is not UTF-8.
                self.negated = true
            return ranges
    self.pos = at
    if in_class and name.len() > 1 and class_ranges(int(str.ascii_lower(name[0]))).len() > 0:
        return self.fail('In a class, the name of a class goes on to the last letter, digit or `_`, so this reads as `' + '%' + name + '`. Put the other characters first: `[' + name[1..] + '%' + name[0..1] + ']`.')
    return self.fail('Unknown class `' + '%' + name + '`. The classes are `%a %c %d %g %l %p %s %u %w %x`, their upper case forms for the opposite, and `%nl`.')

fn (&&Builder) parse_class() -> !int:
    open := self.pos
    self.pos += 1
    negated := false
    if self.peek() == '^':
        negated = true
        self.pos += 1
    var ranges []int = {}
    while:
        c := self.peek()
        if c == -1:
            return self.fail_at(open, 'This class is not closed.')
        if c == ']':
            self.pos += 1
            break
        if c == '%':
            self.pos += 1
            for self.parse_percent(true)! |v|:
                ranges.append(v)
            continue
        lo := 0
        if c == '\\':
            self.pos += 1
            lo = self.parse_escape()!
        else:
            lo = self.rune()
        hi := lo
        if self.peek() == '-' and self.peek_at(1) != ']' and self.peek_at(1) != -1:
            at := self.pos
            self.pos += 1
            if self.peek() == '\\':
                self.pos += 1
                hi = self.parse_escape()!
            else:
                hi = self.rune()
            if hi < lo:
                return self.fail_at(at, 'The range `%{str.init_rune(lo)}-%{str.init_rune(hi)}` ends before it starts.')
        ranges.append(lo)
        ranges.append(hi)
    if ranges.len() == 0:
        return self.fail_at(open, 'This class is empty. Write `\\]` for a `]` in a class.')
    return self.set_node(ranges, negated, open)

fn (&&Builder) expect_close(open int, close str, what str) -> !void:
    self.skip()
    for 0..close.len() |i|:
        if self.peek_at(i) != int(close[i]):
            return self.fail('Expected `%{close}` to close the %{what} that starts at offset %{open}, found %{show(self.peek())}.')
    self.pos += close.len()

fn (&&Builder) cap(child int, kind int, aux int, from int) -> !int:
    depth := 0
    if child >= 0:
        depth = self.nodes[child].depth + 1
    return self.add(Node{kind=NCap, a=child, b=kind, c=aux, from=from, to=self.pos, depth=depth})

fn (&&Builder) parse_primary() -> !int:
    from := self.pos
    c := self.peek()
    switch c:
        case '(':
            self.pos += 1
            node := self.parse_alt()!
            self.expect_close(from, ')', 'group')!
            return node
        case '\'', '"':
            lit := self.parse_literal()!
            if self.peek() == 'i' and !is_name_char(self.peek_at(1)):
                self.pos += 1
                return self.fold_literal(lit, from)
            return self.add(Node{kind=NStr, a=lit.a, b=lit.b, from=from, to=self.pos})
        case '[':
            return self.parse_class()
        case '.':
            self.pos += 1
            return self.add(Node{kind=NAny, from=from, to=self.pos})
        case '%':
            self.pos += 1
            self.negated = false
            ranges := self.parse_percent(false)!
            return self.set_node(ranges, self.negated, from)
        case '=':
            self.pos += 1
            name := self.read_name()
            if name.len() == 0:
                return self.fail_at(from, 'Expected the name of a capture after `=`, as in `=quote`.')
            return self.add(Node{kind=NBackref, a=self.name_id(name), from=from, to=self.pos})
        case '<':
            return self.fail('Write the name of a rule without `<` and `>`.')
        case '{':
            return self.parse_capture()
        else:
            if is_name_start(c):
                name := self.read_name()
                self.calls.append(name)
                return self.add(Node{kind=NCall, a=self.calls.len() - 1, from=from, to=self.pos})
            if c == '*' or c == '+' or c == '?' or c == '^':
                return self.fail('The repetition %{show(c)} has nothing to repeat. Write `\'%{str.init_rune(c)}\'` to match the character.')
            if c == '\\':
                return self.fail('An escape such as `\\n` goes inside a string or a class: `\'\\n\'`. The classes are `%d`, `%s`, `%w` and so on, not `\\d`.')
            if c == '|':
                return self.fail('A choice is written `a / b`, not `a | b`.')
            if c == '$':
                return self.fail('The end of the input is `!.`, not `$`.')
            if c >= 0x80:
                save := self.pos
                cp := self.rune()
                self.pos = save
                return self.fail('Unexpected %{show(cp)}. Text goes in quotes: `\'%{str.init_rune(cp)}\'`.')
            return self.fail('Unexpected %{show(c)}. Text goes in quotes: `\'%{str.init_rune(c)}\'`.')

fn (&&Builder) parse_capture() -> !int:
    from := self.pos
    self.enter()!
    self.pos += 1
    c := self.peek()
    var node int = 0
    if c == '}':
        self.pos += 1
        node = self.cap(-1, CapPos, 0, from)!
    else c == '|':
        return self.fail_at(from, 'A table capture `{| p |}` is not needed: a capture already holds the captures inside it. Write `{ p }` or `{:name: p :}`.')
    else c == '~':
        self.pos += 1
        child := self.parse_alt()!
        self.expect_close(from, '~}', 'capture')!
        node = self.cap(child, CapSubst, 0, from)!
    else c == ':':
        self.pos += 1
        name := self.read_name()
        if name.len() == 0 or self.peek() != ':' or self.peek_at(1) == '}':
            return self.fail_at(from, 'A named capture is `{:name: p :}`. For a capture without a name, write `{ p }`.')
        self.pos += 1
        child := self.parse_alt()!
        self.expect_close(from, ':}', 'capture')!
        node = self.cap(child, CapNamed, self.name_id(name), from)!
    else:
        child := self.parse_alt()!
        self.expect_close(from, '}', 'capture')!
        node = self.cap(child, CapSimple, 0, from)!
    self.depth -= 1
    return node

-- Points each call at its rule.
fn (&&Builder) resolve() -> !void:
    for 0..self.nodes.len() |i|:
        if self.nodes[i].kind != NCall:
            continue
        name := self.calls[self.nodes[i].a]
        found := -1
        for 0..self.rules.len() |r|:
            if self.rules[r] == name:
                found = r
        if found == -1:
            if self.rules.len() == 0:
                return self.fail_at(self.nodes[i].from, 'There is no rule `%{name}`. Text goes in quotes: `\'%{name}\'`. A rule is defined as `%{name} <- ...`.')
            return self.fail_at(self.nodes[i].from, 'The rule `%{name}` is not defined.')
        self.nodes[i].a = found

-- Whether a node can match without taking input.
fn (&Builder) nullable(n int) -> bool:
    node := self.nodes[n]
    switch node.kind:
        case NEmpty, NAnd, NNot, NBackref:
            return true
        case NStr:
            return node.b == 0
        case NAny, NSet:
            return false
        case NSeq:
            for 0..node.b |i|:
                if !self.nullable(self.kids[node.a + i]):
                    return false
            return true
        case NAlt:
            for 0..node.b |i|:
                if self.nullable(self.kids[node.a + i]):
                    return true
            return false
        case NRep:
            return node.b == 0 or self.nullable(node.a)
        case NCall:
            return self.nulls[node.a]
        case NCap:
            return node.a == -1 or self.nullable(node.a)
        else:
            return true

-- Collects the rules that a node can call before it takes input.
fn (&Builder) left_calls(n int, out &&[]int):
    node := self.nodes[n]
    switch node.kind:
        case NSeq:
            for 0..node.b |i|:
                kid := self.kids[node.a + i]
                self.left_calls(kid, out)
                if !self.nullable(kid):
                    break
        case NAlt:
            for 0..node.b |i|:
                self.left_calls(self.kids[node.a + i], out)
        case NRep:
            -- `p^0` never runs `p`.
            if node.c != 0:
                self.left_calls(node.a, out)
        case NAnd, NNot:
            self.left_calls(node.a, out)
        case NCap:
            if node.a != -1:
                self.left_calls(node.a, out)
        case NCall:
            out.append(node.a)
        else:
            pass

fn (&&Builder) check() -> !void:
    nrules := self.rules.len()
    if nrules > 0:
        self.nulls = []bool(nrules, false)
        changed := true
        while changed:
            changed = false
            for 0..nrules |r|:
                if !self.nulls[r] and self.nullable(self.roots[r]):
                    self.nulls[r] = true
                    changed = true
        -- A rule that reaches itself before it takes input never ends.
        var edges [][]int = {}
        for 0..nrules |r|:
            var out []int = {}
            self.left_calls(self.roots[r], &&out)
            edges.append(out)
        for 0..nrules |r|:
            -- `prev[x]` is the rule that led to `x`, -1 when `x` was not reached.
            prev := []int(nrules, -1)
            var queue []int = {r}
            qi := 0
            while qi < queue.len():
                cur := queue[qi]
                qi += 1
                for edges[cur] |next|:
                    if next == r:
                        path := self.rules[r]
                        var chain []int = {}
                        x := cur
                        while x != r:
                            chain.append(x)
                            x = prev[x]
                        via := ''
                        i := chain.len() - 1
                        while i >= 0:
                            via += ' -> ' + self.rules[chain[i]]
                            i -= 1
                        return self.fail_at(self.rule_at[r], 'The rule `%{path}` is left recursive (%{path}%{via} -> %{path}): it calls itself before it takes any input, which never ends. Write the repetition as a loop: `a <- b (op b)*`.')
                    if prev[next] == -1 and next != r:
                        prev[next] = cur
                        queue.append(next)
    for 0..self.nodes.len() |i|:
        node := self.nodes[i]
        if node.kind == NRep and node.c == -1 and self.nullable(node.a):
            return self.fail_at(node.from, 'This repetition never ends: what it repeats can match without taking any input.')

fn (&Builder) here() -> int:
    return self.insts.len() / 3

fn (&&Builder) emit(op int, a int, b int) -> !int:
    if self.insts.len() / 3 >= MaxInsts:
        self.msg = 'The grammar is too big: its program has more than %{MaxInsts} instructions.'
        self.err_pos = 0
        return error.TooBig
    self.insts.append(op)
    self.insts.append(a)
    self.insts.append(b)
    return self.insts.len() / 3 - 1

fn (&Builder) patch(pc int):
    self.insts[pc * 3 + 1] = self.here()

-- Notes what the instruction `pc` expects, for the message of a failed `parse`.
fn (&&Builder) expects(pc int, txt str):
    self.exp_pc.append(pc)
    self.exp_txt.append(txt)

-- The text of a node in the grammar, on one line and not too long.
fn (&Builder) text_of(n int) -> str:
    node := self.nodes[n]
    txt := self.src[node.from..node.to].trim(' \t\r\n')
    if txt.len() > 40 or txt.index('\n') != none:
        end := 0
        while end < txt.len() and end < 37 and txt[end] != '\n':
            end += unit_len(txt, end)
        return txt[0..end] + '...'
    return txt

fn (&&Builder) gen(n int) -> !void:
    self.work += 1
    if self.work > MaxInsts * 8:
        self.msg = 'The grammar is too big: it repeats too many times.'
        self.err_pos = 0
        return error.TooBig
    node := self.nodes[n]
    switch node.kind:
        case NEmpty:
            pass
        case NStr:
            if node.b > 0:
                op := OpStr
                if node.c == 1:
                    op = OpStrFold
                pc := self.emit(op, HeaderLen + node.a, node.b)!
                self.expects(pc, self.text_of(n))
        case NAny:
            pc := self.emit(OpAny, 0, 0)!
            self.expects(pc, 'any character')
        case NSet:
            pc := self.emit(OpSet, HeaderLen + self.lits.len() + node.a, 0)!
            self.expects(pc, self.text_of(n))
        case NSeq:
            for 0..node.b |i|:
                self.gen(self.kids[node.a + i])!
        case NAlt:
            var ends []int = {}
            for 0..node.b - 1 |i|:
                choice := self.emit(OpChoice, 0, 0)!
                self.gen(self.kids[node.a + i])!
                ends.append(self.emit(OpCommit, 0, 0)!)
                self.patch(choice)
            self.gen(self.kids[node.a + node.b - 1])!
            for ends |pc|:
                self.patch(pc)
        case NRep:
            for 0..node.b |_i|:
                self.gen(node.a)!
            if node.c == -1:
                if self.nodes[node.a].kind == NSet:
                    span := self.emit(OpSpan, HeaderLen + self.lits.len() + self.nodes[node.a].a, 0)!
                    -- Where it stops, the set was expected, as in the loop that it stands for.
                    self.expects(span, self.text_of(node.a))
                else:
                    choice := self.emit(OpChoice, 0, 0)!
                    top := self.here()
                    self.gen(node.a)!
                    _ = self.emit(OpPartialCommit, top, 0)!
                    self.patch(choice)
            else node.c > node.b:
                -- `p?` up to `max - min` times: one choice that moves on after each `p`.
                choice := self.emit(OpChoice, 0, 0)!
                for 0..node.c - node.b - 1 |_i|:
                    self.gen(node.a)!
                    pc := self.emit(OpPartialCommit, 0, 0)!
                    self.patch(pc)
                self.gen(node.a)!
                pc := self.emit(OpCommit, 0, 0)!
                self.patch(pc)
                self.patch(choice)
        case NAnd:
            choice := self.emit(OpChoice, 0, 1)!
            self.gen(node.a)!
            back := self.emit(OpBackCommit, 0, 0)!
            self.patch(choice)
            pc := self.emit(OpFail, 0, 0)!
            self.expects(pc, self.text_of(node.a))
            self.patch(back)
        case NNot:
            choice := self.emit(OpChoice, 0, 1)!
            self.gen(node.a)!
            pc := self.emit(OpFailTwice, 0, 0)!
            if self.nodes[node.a].kind == NAny:
                self.expects(pc, 'the end of the input')
            else:
                self.expects(pc, 'not ' + self.text_of(node.a))
            self.patch(choice)
        case NCall:
            pc := self.emit(OpCall, node.a, 0)!
            self.fixes.append(pc)
        case NCap:
            if node.b == CapPos:
                _ = self.emit(OpOpen, CapSimple, 0)!
                _ = self.emit(OpClose, 0, 0)!
            else:
                _ = self.emit(OpOpen, node.b, node.c)!
                self.gen(node.a)!
                _ = self.emit(OpClose, 0, 0)!
        case NBackref:
            pc := self.emit(OpBackref, node.a, 0)!
            self.expects(pc, self.text_of(n))
        else:
            pass

fn (&&Builder) gen_all() -> !void:
    if self.rules.len() == 0:
        self.gen(self.roots[0])!
        _ = self.emit(OpEnd, 0, 0)!
        return
    first := self.emit(OpCall, 0, 0)!
    self.fixes.append(first)
    _ = self.emit(OpEnd, 0, 0)!
    var addrs []int = {}
    for 0..self.rules.len() |r|:
        addrs.append(self.here())
        self.gen(self.roots[r])!
        _ = self.emit(OpRet, 0, 0)!
    for self.fixes |pc|:
        self.insts[pc * 3 + 1] = addrs[self.insts[pc * 3 + 1]]
        -- A call at the end of a rule needs no way back.
        if pc != first and self.insts[(pc + 1) * 3] == OpRet:
            self.insts[pc * 3] = OpJmp

fn (&Builder) assemble() -> []int:
    inst_off := HeaderLen + self.lits.len() + self.sets.len()
    var prog []int = {Magic, self.insts.len() / 3, inst_off, 0, 0, 0, 0, 0}
    prog.append(self.lits.span())
    prog.append(self.sets.span())
    prog.append(self.insts.span())
    return prog
