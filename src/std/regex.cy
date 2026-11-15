--| Regular expressions without backtracking: a search takes time linear in the length of the input.
--| The syntax is a subset of the Rust `regex` crate's, which is the default syntax of ripgrep.
--| A pattern that compiles matches what it matches there. There are no look-arounds and no backreferences.
--| Matching is by Unicode code point (`\w`, `\d`, `\s`, `\b` and `(?i)` are Unicode aware), offsets are in bytes.
--| Sample usage:
--| ```cy
--| use regex
--|
--| re := regex.compile(`(?P<key>\w+)=(\d+)`)!
--| line := 'retries=3 timeout=250'
--| print(re.is_match(line))              --> true
--| print(re.find(line).?.text)           --> retries=3
--| for re.captures_all(line) |c|:
--|     print('%{c['key']} -> %{c[2]}')   --> retries -> 3, timeout -> 250
--| print(re.replace_all(line, '$2=$key'))  --> 3=retries 250=timeout
--|
--| var diag regex.Diag = {}
--| try:
--|     _ = regex.compile('a(?=b)', &diag)!
--| else |err|:
--|     print('%{err} at %{diag.pos}: %{diag.msg}')
--| ```

--| Compiling stops with `error.TooBig` when the program of a pattern has more instructions than this.
--| Counted repetitions are expanded: `\w{100}` takes 100 instructions.
const MaxInsts = 32768

--| Compiling stops with `error.Syntax` when groups, classes and repetitions nest deeper than this.
const MaxDepth = 250

--| Where and why compiling failed. `pos` is a byte offset into the pattern.
type Diag:
    msg str = ''
    pos int = 0

--| A match: the bytes `start..end` of the input and their text.
type Match:
    start int
    end   int
    text  str

--| A compiled pattern. It does not change and can be used for any number of searches.
type Regex:
    -prog   []int
    -names  []str
    -source str

--| The groups of one match. Group 0 is the whole match.
type Captures:
    -hay   str
    -slots []int
    -names []str

-- Program layout, shared with `regex.zig`. A program is one `[]int`:
--   header (8 words): magic, instruction count, slot count, flags, prefix length, prefix offset, instruction offset, 0
--   prefix: the bytes of the literal that every match starts with, one byte a word
--   sets: `ascii_lo, ascii_hi, flags, nops`, then `nops` set ops of three words in postfix order
--   instructions: three words each, `op, a, b`
const Magic = 0x52450001
const HeaderLen = 8
const FlagAnchored = 1
const MaxPrefix = 64

const OpMatch = 0
const OpChar = 1
const OpAny = 2
const OpAnyNl = 3
const OpSet = 4
const OpSplit = 5
const OpJmp = 6
const OpSave = 7
const OpAssert = 8

const AsStartText = 0
const AsEndText = 1
const AsStartLine = 2
const AsEndLine = 3
const AsWord = 4
const AsNotWord = 5
const AsWordStart = 6
const AsWordEnd = 7
const AsWordStartHalf = 8
const AsWordEndHalf = 9

const SetRange = 0
const SetTable = 1
const SetOr = 2
const SetAnd = 3
const SetDiff = 4
const SetXor = 5
const SetNot = 6
const SetFold = 1

-- Flags of the parser.
const FlagI = 1
const FlagM = 2
const FlagS = 4
const FlagSwap = 8
const FlagX = 16

-- Node kinds.
const NEmpty = 0
const NChar = 1      -- a: code point
const NAny = 2       -- a: 1 when it also matches `\n`
const NSet = 3       -- a: offset in `sets`
const NAssert = 4    -- a: assertion
const NCat = 5       -- a: first child in `kids`, b: count
const NAlt = 6       -- a: first child in `kids`, b: count
const NRepeat = 7    -- a: child, b: min, c: max or -1, d: 1 when greedy
const NGroup = 8     -- a: child, b: group number

-type Node:
    kind  int
    a     int = 0
    b     int = 0
    c     int = 0
    d     int = 0
    -- Nesting depth below this node, and whether it can match the empty string.
    depth int = 0
    empty bool = false

#[bind]
-fn exec_(prog [&]int, hay str, start int, skip bool, slots [&]int, work [&]int) -> int

-- Whether the search finds a match. When the host asks the VM to stop, the search ends without a result, and the
-- checkpoint of this loop stops the VM before it runs again: it is never taken for a failed search.
-fn exec(prog [&]int, hay str, start int, skip bool, slots [&]int, work [&]int) -> bool:
    while:
        res := exec_(prog, hay, start, skip, slots, work)
        if res >= 0:
            return res == 1

--| The length of the scratch buffer that `exec` uses for `nslots` slots. A repeated search makes it once.
#[bind]
-fn work_len(prog [&]int, nslots int) -> int

#[bind]
-fn set_ascii(sets [&]int, off int, half int) -> int

#[bind]
-fn uni_table(name str, kind int) -> int

--| Returns the version of the Unicode Character Database that the classes come from, such as `18.0.0`.
#[bind]
fn unicode_version() -> str

--| Compiles a pattern. Returns `error.Syntax` for a pattern that is malformed or uses a feature that is not supported,
--| and `error.TooBig` for one that is over `MaxInsts`.
fn compile(pattern str) -> !Regex:
    var diag Diag = {}
    return compile(pattern, &diag)

--| Compiles a pattern. On failure, `diag` tells where and why.
fn compile(pattern str, diag &Diag) -> !Regex:
    diag.msg = ''
    diag.pos = 0
    if !str.is_utf8(pattern.span()):
        diag.msg = 'The pattern is not valid UTF-8.'
        return error.Syntax
    b := Builder{src=pattern}
    root := b.parse_alt() !else |err|:
        diag.msg = b.msg
        diag.pos = b.err_pos
        return err
    if b.pos < pattern.len():
        diag.msg = 'This `)` closes no group. Write `\\)` to match a parenthesis.'
        diag.pos = b.pos
        return error.Syntax
    b.gen_all(root) !else |err|:
        diag.msg = b.msg
        diag.pos = 0
        return err
    return Regex{prog=b.assemble(), names=b.names, source=pattern}

--| Returns `s` with every character that has a meaning in a pattern escaped, so that it matches itself.
fn escape(s str) -> str:
    res := ''
    last := 0
    for 0..s.len() |i|:
        c := int(s[i])
        if is_meta(c):
            res += s[last..i] + '\\'
            last = i
    return res + s[last..]

-fn is_meta(c int) -> bool:
    switch c:
        case '\\', '.', '+', '*', '?', '(', ')', '|', '[', ']', '{', '}', '^', '$', '#', '&', '-', '~':
            return true
        else:
            return false

--| Returns the pattern that this was compiled from.
fn (&Regex) pattern() -> str:
    return self.source

--| Returns the number of groups, with group 0 (the whole match).
fn (&Regex) captures_len() -> int:
    return self.names.len()

--| Returns the names of the groups by number. A group without a name, as group 0, has `''`.
fn (&Regex) capture_names() -> []str:
    return self.names

--| Returns whether the pattern matches anywhere in `s`.
fn (&Regex) is_match(s str) -> bool:
    var slots []int = {}
    var work []int = {}
    return exec(self.prog.span(), s, 0, false, slots.span(), work.span())

--| Returns the leftmost match in `s`.
fn (&Regex) find(s str) -> ?Match:
    return self.find(s, 0)

--| Returns the leftmost match that starts at byte `start` or later. `^`, `\b` and the like still see all of `s`.
fn (&Regex) find(s str, start int) -> ?Match:
    slots := []int(2, -1)
    var work []int = {}
    if !exec(self.prog.span(), s, start, false, slots.span(), work.span()):
        return none
    return Match{start=slots[0], end=slots[1], text=s[slots[0]..slots[1]]}

--| Returns every match in `s` from left to right. The matches do not overlap. An empty match that touches the end
--| of the match before it is left out.
fn (&Regex) find_all(s str) -> []Match:
    var res []Match = {}
    slots := []int(2, -1)
    work := []int(work_len(self.prog.span(), 2), 0)
    at := 0
    last_end := -1
    skip := false
    while exec(self.prog.span(), s, at, skip, slots.span(), work.span()):
        skip = false
        if slots[0] == slots[1] and slots[1] == last_end:
            -- Search again past the next code point.
            skip = true
            continue
        res = res.append(Match{start=slots[0], end=slots[1], text=s[slots[0]..slots[1]]})
        last_end = slots[1]
        at = slots[1]
    return res

--| Returns the groups of the leftmost match in `s`.
fn (&Regex) captures(s str) -> ?Captures:
    return self.captures(s, 0)

--| Returns the groups of the leftmost match that starts at byte `start` or later.
fn (&Regex) captures(s str, start int) -> ?Captures:
    slots := []int(self.names.len() * 2, -1)
    var work []int = {}
    if !exec(self.prog.span(), s, start, false, slots.span(), work.span()):
        return none
    return Captures{hay=s, slots=slots, names=self.names}

--| Returns the groups of every match in `s`, see `find_all`.
fn (&Regex) captures_all(s str) -> []Captures:
    var res []Captures = {}
    work := []int(work_len(self.prog.span(), self.names.len() * 2), 0)
    at := 0
    last_end := -1
    skip := false
    while:
        slots := []int(self.names.len() * 2, -1)
        if !exec(self.prog.span(), s, at, skip, slots.span(), work.span()):
            break
        skip = false
        if slots[0] == slots[1] and slots[1] == last_end:
            skip = true
            continue
        last_end = slots[1]
        at = slots[1]
        res = res.append(Captures{hay=s, slots=slots, names=self.names})
    return res

--| Returns `s` with the leftmost match replaced by `repl`, see `replace_all`.
fn (&Regex) replace(s str, repl str) -> str:
    return self.replace_n(s, repl, 1)

--| Returns `s` with every match replaced by `repl`.
--| In `repl`, `$1` and `${1}` stand for a group by number, `$name` and `${name}` by name, and `$$` for a `$`.
--| A name takes the longest run of letters, digits and `_`: write `${1}a`, since `$1a` is the group named `1a`.
--| A group that does not exist or did not take part gives nothing.
fn (&Regex) replace_all(s str, repl str) -> str:
    return self.replace_n(s, repl, 0)

-fn (&Regex) replace_n(s str, repl str, limit int) -> str:
    if repl.index('$') == none:
        if limit == 1:
            if self.find(s) |m|:
                return s[0..m.start] + repl + s[m.end..]
            return s
        -- One buffer for the result, so that the copying stays linear in the number of matches.
        var buf []byte = {}
        last := 0
        for self.find_all(s) |m|:
            buf = buf.append(s[last..m.start].span())
            buf = buf.append(repl.span())
            last = m.end
        buf = buf.append(s[last..].span())
        return str(buf)
    if limit == 1:
        if self.captures(s) |c|:
            m := c.get(0).?
            return s[0..m.start] + c.expand(repl) + s[m.end..]
        return s
    var buf []byte = {}
    last := 0
    for self.captures_all(s) |c|:
        m := c.get(0).?
        buf = buf.append(s[last..m.start].span())
        buf = buf.append(c.expand(repl).span())
        last = m.end
    buf = buf.append(s[last..].span())
    return str(buf)

--| Returns the pieces of `s` between the matches. Groups are not part of the result.
fn (&Regex) split(s str) -> []str:
    var res []str = {}
    last := 0
    for self.find_all(s) |m|:
        res = res.append(s[last..m.start])
        last = m.end
    return res.append(s[last..])

--| Returns at most `limit` pieces of `s`. The last piece is the rest of the input.
fn (&Regex) split(s str, limit int) -> []str:
    var res []str = {}
    if limit <= 0:
        return res
    last := 0
    for self.find_all(s) |m|:
        if res.len() + 1 >= limit:
            break
        res = res.append(s[last..m.start])
        last = m.end
    return res.append(s[last..])

--| Returns the number of groups, with group 0.
fn (&Captures) len() -> int:
    return self.names.len()

--| Returns group `i`, or `none` when it did not take part in the match or does not exist.
fn (&Captures) get(i int) -> ?Match:
    if i < 0 or i >= self.names.len():
        return none
    start := self.slots[i * 2]
    end := self.slots[i * 2 + 1]
    if start < 0 or end < 0:
        return none
    return Match{start=start, end=end, text=self.hay[start..end]}

--| Returns the group named `name`, or `none` when it did not take part in the match or does not exist.
fn (&Captures) get(name str) -> ?Match:
    if self.index_of(name) |i|:
        return self.get(i)
    return none

-fn (&Captures) index_of(name str) -> ?int:
    if name.len() == 0:
        return none
    for 1..self.names.len() |i|:
        if self.names[i] == name:
            return i
    return none

--| Returns the text of group `i`, `''` when it did not take part in the match. Panics for a group that does not exist.
fn (&Captures) @index(i int) -> str:
    if i < 0 or i >= self.names.len():
        panic('Group %{i} does not exist. The pattern has groups 0..%{self.names.len() - 1}.')
    if self.get(i) |m|:
        return m.text
    return ''

--| Returns the text of the group named `name`, `''` when it did not take part in the match.
--| Panics for a name that the pattern does not have.
fn (&Captures) @index(name str) -> str:
    i := self.index_of(name) ?else panic('The pattern has no group named `%{name}`.')
    return self[i]

--| Returns `repl` with its group references replaced, see `Regex.replace_all`.
fn (&Captures) expand(repl str) -> str:
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
            while j < n and is_ref_char(int(repl[j])):
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
            if self.get(num) |m|:
                res += m.text
        else:
            if self.get(name) |m|:
                res += m.text
        i = ref_end
        last = i
    return res + repl[last..]

-fn is_ref_char(c int) -> bool:
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_'

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

--| Shows a character of a pattern in a message.
-fn show(cp int) -> str:
    if cp < 0:
        return 'the end of the pattern'
    if cp == '\n':
        return 'a line feed'
    if cp < 32 or cp == 127:
        return 'the control character %{cp}'
    return '`' + str.initRune(cp) + '`'

-- Lower case without `_`, `-` and spaces: the loose form of a property value name (UAX44-LM3).
-fn loose(name str) -> str:
    res := ''
    for 0..name.len() |i|:
        c := name[i]
        if c == '_' or c == '-' or c == ' ':
            continue
        res += str.initRune(int(str.ascii_lower(c)))
    return res

-- The parser and the code generator. The pattern becomes nodes, the nodes become instructions.
-type Builder:
    src     str
    pos     int = 0
    msg     str = ''
    err_pos int = 0
    flags   int = 0
    -- Open groups and classes.
    depth   int = 0
    nodes   []Node = {}
    kids    []int = {}
    sets    []int = {}
    -- The ops of the class that is being parsed.
    ops     []int = {}
    names   []str = {''}
    insts   []int = {}
    -- Nodes visited by `gen`, to stop a pattern that repeats nothing a great many times.
    work    int = 0

fn (&Builder) fail(msg str) -> error:
    self.msg = msg
    self.err_pos = self.pos
    return error.Syntax

fn (&Builder) fail_at(pos int, msg str) -> error:
    self.msg = msg
    self.err_pos = pos
    return error.Syntax

fn (&Builder) too_big(msg str) -> error:
    self.msg = msg
    self.err_pos = self.pos
    return error.TooBig

fn (&Builder) has(flag int) -> bool:
    return (self.flags && flag) != 0

-- Returns the byte at `pos + off`, or -1 past the end.
fn (&Builder) peek_at(off int) -> int:
    if self.pos + off < self.src.len():
        return int(self.src[self.pos + off])
    return -1

fn (&Builder) peek() -> int:
    if self.pos < self.src.len():
        return int(self.src[self.pos])
    return -1

-- Reads the code point at `pos`.
fn (&Builder) rune() -> int:
    cp := int(self.src.rune_at(self.pos))
    self.pos += rune_len(cp)
    return cp

-- In `x` mode, skips white space and `#` comments.
fn (&Builder) skip_x():
    if !self.has(FlagX):
        return
    while self.pos < self.src.len():
        c := self.src[self.pos]
        if c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 11 or c == 12:
            self.pos += 1
        else c == '#':
            while self.pos < self.src.len() and self.src[self.pos] != '\n':
                self.pos += 1
        else:
            return

fn (&Builder) add(node Node) -> !int:
    if node.depth > MaxDepth:
        return self.fail('The pattern nests deeper than %{MaxDepth} levels.')
    self.nodes = self.nodes.append(node)
    return self.nodes.len() - 1

fn (&Builder) enter(open int) -> !void:
    self.depth += 1
    if self.depth > MaxDepth:
        return self.fail_at(open, 'The pattern nests deeper than %{MaxDepth} levels.')

-- Joins child nodes into a concatenation or an alternation.
fn (&Builder) join(kind int, items []int) -> !int:
    start := self.kids.len()
    depth := 0
    empty := kind == NCat
    for items |n|:
        self.kids = self.kids.append(n)
        if self.nodes[n].depth > depth:
            depth = self.nodes[n].depth
        if kind == NCat:
            empty = empty and self.nodes[n].empty
        else:
            empty = empty or self.nodes[n].empty
    return self.add(Node{kind=kind, a=start, b=items.len(), depth=depth + 1, empty=empty})

-- alt := cat ('|' cat)*. Stops at `)` and at the end.
fn (&Builder) parse_alt() -> !int:
    var branches []int = {}
    branches = branches.append(self.parse_cat()!)
    while self.peek() == '|':
        self.pos += 1
        branches = branches.append(self.parse_cat()!)
    if branches.len() == 1:
        return branches[0]
    return self.join(NAlt, branches)

fn (&Builder) parse_cat() -> !int:
    var items []int = {}
    while:
        self.skip_x()
        c := self.peek()
        if c == -1 or c == '|' or c == ')':
            break
        if c == '*' or c == '+' or c == '?' or c == '{':
            return self.fail('The repetition %{show(c)} has nothing to repeat. Write `\\%{str.initRune(c)}` to match the character.')
        node := self.parse_atom()!
        if node == -1:
            -- `(?flags)` sets flags and matches nothing.
            self.skip_x()
            r := self.peek()
            if r == '*' or r == '+' or r == '?' or r == '{':
                return self.fail('The repetition %{show(r)} has nothing to repeat.')
            continue
        while:
            self.skip_x()
            r := self.peek()
            if r == '*' or r == '+' or r == '?' or r == '{':
                node = self.parse_repeat(node)!
            else:
                break
        items = items.append(node)
    if items.len() == 0:
        return self.add(Node{kind=NEmpty, empty=true})
    if items.len() == 1:
        return items[0]
    return self.join(NCat, items)

fn (&Builder) parse_number() -> !int:
    start := self.pos
    n := 0
    while is_digit(self.peek()):
        if n <= MaxInsts:
            n = n * 10 + (self.peek() - '0')
        self.pos += 1
    if self.pos == start:
        return self.fail('Expected a number in the repetition `{n}`, `{n,}` or `{n,m}`, found %{show(self.peek())}. Write `\\{` to match a brace.')
    if n > MaxInsts:
        self.pos = start
        return self.too_big('The repetition count is over the limit of %{MaxInsts}.')
    return n

fn (&Builder) parse_repeat(child int) -> !int:
    open := self.pos
    c := self.peek()
    self.pos += 1
    min := 0
    max := -1
    if c == '+':
        min = 1
    else c == '?':
        max = 1
    else c == '{':
        self.skip_x()
        min = self.parse_number()!
        max = min
        self.skip_x()
        if self.peek() == ',':
            self.pos += 1
            self.skip_x()
            if is_digit(self.peek()):
                max = self.parse_number()!
            else:
                max = -1
            self.skip_x()
        if self.peek() != '}':
            return self.fail('Expected `}` to close the repetition, found %{show(self.peek())}.')
        self.pos += 1
        if max != -1 and max < min:
            return self.fail_at(open, 'The repetition `{%{min},%{max}}` has a minimum over its maximum.')
    greedy := true
    if self.peek() == '?':
        self.pos += 1
        greedy = false
    if self.has(FlagSwap):
        greedy = !greedy
    g := 0
    if greedy:
        g = 1
    cn := self.nodes[child]
    return self.add(Node{kind=NRepeat, a=child, b=min, c=max, d=g, depth=cn.depth + 1, empty=min == 0 or cn.empty})

fn (&Builder) assertion(kind int) -> !int:
    return self.add(Node{kind=NAssert, a=kind, empty=true})

-- Returns a node, or -1 for `(?flags)`.
fn (&Builder) parse_atom() -> !int:
    c := self.peek()
    switch c:
        case '(':
            return self.parse_group()
        case '[':
            self.ops = {}
            self.class_bracket()!
            return self.finish_set(self.has(FlagI))
        case '.':
            self.pos += 1
            nl := 0
            if self.has(FlagS):
                nl = 1
            return self.add(Node{kind=NAny, a=nl})
        case '^':
            self.pos += 1
            if self.has(FlagM):
                return self.assertion(AsStartLine)
            return self.assertion(AsStartText)
        case '$':
            self.pos += 1
            if self.has(FlagM):
                return self.assertion(AsEndLine)
            return self.assertion(AsEndText)
        case '\\':
            return self.parse_escape()
        else:
            return self.literal(self.rune())

fn (&Builder) literal(cp int) -> !int:
    if self.has(FlagI) and (cp >= 128 or is_alpha(cp)):
        self.ops = {}
        self.leaf(SetRange, cp, cp)
        return self.finish_set(true)
    return self.add(Node{kind=NChar, a=cp})

fn (&Builder) leaf(op int, a int, b int):
    self.ops = self.ops.append(op)
    self.ops = self.ops.append(a)
    self.ops = self.ops.append(b)

-- Makes a set of the ops in `ops` and returns its node.
fn (&Builder) finish_set(fold bool) -> !int:
    off := self.sets.len()
    flags := 0
    if fold:
        flags = SetFold
    self.sets = self.sets.append(0)
    self.sets = self.sets.append(0)
    self.sets = self.sets.append(flags)
    self.sets = self.sets.append(self.ops.len() / 3)
    self.sets = self.sets.append(self.ops.span())
    self.sets[off] = set_ascii(self.sets.span(), off, 0)
    self.sets[off + 1] = set_ascii(self.sets.span(), off, 1)
    return self.add(Node{kind=NSet, a=off})

fn (&Builder) parse_group() -> !int:
    open := self.pos
    self.pos += 1
    saved := self.flags
    group := -1
    if self.peek() == '?':
        c1 := self.peek_at(1)
        c2 := self.peek_at(2)
        if c1 == '=' or c1 == '!':
            return self.fail_at(open, 'Look-ahead (`(?=...)`, `(?!...)`) is not supported: matching never backtracks. Match the text that follows as part of the pattern and take the part you need with a group.')
        if c1 == '<' and (c2 == '=' or c2 == '!'):
            return self.fail_at(open, 'Look-behind (`(?<=...)`, `(?<!...)`) is not supported: matching never backtracks. Match the text before as part of the pattern and take the part you need with a group.')
        if c1 == '>':
            return self.fail_at(open, 'Atomic groups (`(?>...)`) are not supported. Nothing backtracks here, so `(?:...)` is as fast.')
        if c1 == '#':
            return self.fail_at(open, 'Comment groups (`(?#...)`) are not supported. Use the `x` flag, `(?x)`, and `#` comments.')
        if c1 == '(':
            return self.fail_at(open, 'Conditional groups (`(?(...)...)`) are not supported.')
        if c1 == 'P' and c2 == '=':
            return self.fail_at(open, 'Backreferences (`(?P=name)`) are not supported: matching never backtracks. Capture both parts and compare them in code.')
        if c1 == 'P' and c2 == '>':
            return self.fail_at(open, 'Recursion (`(?P>name)`) is not supported.')
        if c1 == '<' or (c1 == 'P' and c2 == '<'):
            self.pos += 2
            if c1 == 'P':
                self.pos += 1
            name := self.parse_name()!
            group = self.names.len()
            self.names = self.names.append(name)
        else:
            self.pos += 1
            colon := self.parse_flags(open)!
            if !colon:
                return -1
    else:
        group = self.names.len()
        self.names = self.names.append('')
    self.enter(open)!
    child := self.parse_alt()!
    if self.peek() != ')':
        return self.fail_at(open, 'This group is not closed. Add `)`, or write `\\(` to match a parenthesis.')
    self.pos += 1
    self.depth -= 1
    self.flags = saved
    if group == -1:
        return child
    cn := self.nodes[child]
    return self.add(Node{kind=NGroup, a=child, b=group, depth=cn.depth + 1, empty=cn.empty})

fn (&Builder) parse_name() -> !str:
    start := self.pos
    while:
        c := self.peek()
        if c == -1:
            return self.fail_at(start, 'The group name is not closed. Add `>`.')
        if c == '>':
            break
        ok := is_alpha(c) or c == '_'
        if self.pos > start:
            ok = ok or is_digit(c) or c == '.' or c == '[' or c == ']'
        if !ok:
            return self.fail('A group name starts with a letter or `_` and goes on with letters, digits, `_`, `.`, `[` and `]`. Found %{show(c)}.')
        self.pos += 1
    name := self.src[start..self.pos]
    if name.len() == 0:
        return self.fail('The group name is empty.')
    for self.names |n|:
        if n == name:
            return self.fail_at(start, 'There are two groups named `%{name}`.')
    self.pos += 1
    return name

-- Parses `flags)` or `flags:` after `(?`. Returns whether a group body follows.
fn (&Builder) parse_flags(open int) -> !bool:
    negate := false
    count := 0
    seen := 0
    while:
        c := self.peek()
        if c == -1:
            return self.fail_at(open, 'This group is not closed. Add `)`.')
        if c == ')' or c == ':':
            if count == 0:
                if c == ')' and !negate:
                    return self.fail_at(open, 'Expected a flag (`i`, `m`, `s`, `U`, `x`) after `(?`, found `)`. A group that does not capture is `(?:...)`.')
                if negate:
                    return self.fail('Expected a flag after `-`, found %{show(c)}.')
            self.pos += 1
            return c == ':'
        if c == '-':
            if negate:
                return self.fail('The flags have `-` twice.')
            negate = true
            count = 0
            self.pos += 1
            continue
        bit := 0
        switch c:
            case 'i':
                bit = FlagI
            case 'm':
                bit = FlagM
            case 's':
                bit = FlagS
            case 'U':
                bit = FlagSwap
            case 'x':
                bit = FlagX
            case 'u':
                if negate:
                    return self.fail('The `u` flag can not be turned off: matching is always by Unicode code point. For ASCII only, write the class out: `[0-9]`, `[A-Za-z0-9_]`, `[[:alpha:]]`.')
                bit = 32
            case 'R':
                return self.fail('The `R` flag (CRLF mode) is not supported. Match an optional `\\r` before the line end: `\\r?$`.')
            else:
                if c == 'a' or c == 'L':
                    return self.fail('The flag %{show(c)} is Python\'s. Here the flags are `i`, `m`, `s`, `U` and `x`.')
                return self.fail('Unknown flag %{show(c)}. The flags are `i`, `m`, `s`, `U` and `x`. A group that does not capture is `(?:...)`, a named group `(?P<name>...)`.')
        if (seen && bit) != 0:
            return self.fail('The flag %{show(c)} is given twice.')
        seen = seen || bit
        count += 1
        if bit != 32:
            if negate:
                self.flags = self.flags && (31 - bit)
            else:
                self.flags = self.flags || bit
        self.pos += 1

fn (&Builder) perl_class(c int):
    switch c:
        case 'd', 'D':
            self.leaf(SetTable, uni_table('digit', 3), 0)
        case 's', 'S':
            self.leaf(SetTable, uni_table('space', 3), 0)
        else:
            self.leaf(SetTable, uni_table('word', 3), 0)
    if c == 'D' or c == 'S' or c == 'W':
        self.leaf(SetNot, 0, 0)

-- An escape outside a class. `pos` is at the backslash.
fn (&Builder) parse_escape() -> !int:
    start := self.pos
    c := self.peek_at(1)
    switch c:
        case 'd', 'D', 's', 'S', 'w', 'W':
            self.pos += 2
            self.ops = {}
            self.perl_class(c)
            return self.finish_set(false)
        case 'p', 'P':
            self.ops = {}
            self.unicode_class()!
            return self.finish_set(self.has(FlagI))
        case 'A':
            self.pos += 2
            return self.assertion(AsStartText)
        case 'z':
            self.pos += 2
            return self.assertion(AsEndText)
        case 'B':
            self.pos += 2
            return self.assertion(AsNotWord)
        case '<':
            self.pos += 2
            return self.assertion(AsWordStart)
        case '>':
            self.pos += 2
            return self.assertion(AsWordEnd)
        case 'b':
            self.pos += 2
            if self.peek() == '{':
                -- `\b{start}` and the like. `\b{2}` is a repetition.
                end := self.pos + 1
                while end < self.src.len() and (is_alpha(int(self.src[end])) or self.src[end] == '-'):
                    end += 1
                if end > self.pos + 1 and end < self.src.len() and self.src[end] == '}':
                    name := self.src[self.pos + 1..end]
                    kind := -1
                    if name == 'start':
                        kind = AsWordStart
                    else name == 'end':
                        kind = AsWordEnd
                    else name == 'start-half':
                        kind = AsWordStartHalf
                    else name == 'end-half':
                        kind = AsWordEndHalf
                    else:
                        return self.fail('Unknown word boundary `\\b{%{name}}`. There are `\\b{start}`, `\\b{end}`, `\\b{start-half}` and `\\b{end-half}`.')
                    self.pos = end + 1
                    return self.assertion(kind)
            return self.assertion(AsWord)
        else:
            self.pos += 1
            cp := self.escape_char(start, false)!
            return self.literal(cp)

-- Reads `n` hex digits, or `{...}` when a brace follows.
fn (&Builder) hex_escape(start int, n int) -> !int:
    cp := 0
    if self.peek() == '{':
        self.pos += 1
        digits := 0
        while is_hex(self.peek()):
            if digits < 8:
                cp = cp * 16 + hex_val(self.peek())
            digits += 1
            self.pos += 1
        if self.peek() != '}':
            return self.fail('Expected hex digits and `}` in the escape, found %{show(self.peek())}.')
        self.pos += 1
        if digits == 0 or digits > 8:
            return self.fail_at(start, 'The escape needs one to eight hex digits between the braces.')
    else:
        for 0..n:
            if !is_hex(self.peek()):
                return self.fail('Expected %{n} hex digits in the escape, found %{show(self.peek())}. For another number of digits write `\\x{...}`.')
            cp = cp * 16 + hex_val(self.peek())
            self.pos += 1
    if cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff):
        return self.fail_at(start, 'The escape is not a Unicode code point (0 to 10FFFF without D800 to DFFF).')
    return cp

-- Reads the character of an escape. `pos` is after the backslash, `start` at it.
fn (&Builder) escape_char(start int, in_class bool) -> !int:
    c := self.peek()
    if c == -1:
        return self.fail_at(start, 'The pattern ends with a `\\`. Write `\\\\` to match a backslash.')
    if c >= 128:
        return self.fail_at(start, 'A `\\` before %{show(self.rune())} has no meaning. Remove the `\\`.')
    self.pos += 1
    switch c:
        case 'a':
            return 7
        case 'f':
            return 12
        case 't':
            return 9
        case 'n':
            return 10
        case 'r':
            return 13
        case 'v':
            return 11
        case 'x':
            return self.hex_escape(start, 2)
        case 'u':
            return self.hex_escape(start, 4)
        case 'U':
            return self.hex_escape(start, 8)
        case 'Z':
            return self.fail_at(start, '`\\Z` is not supported. The end of the input is `\\z`. Before an optional last line feed, write `\\n?\\z`.')
        case 'G', 'K', 'X', 'R', 'h', 'H', 'N', 'Q', 'E', 'C', 'k', 'g':
            return self.fail_at(start, 'The escape `\\%{str.initRune(c)}` is not supported.')
        else:
            pass
    if is_digit(c):
        return self.fail_at(start, 'Backreferences (`\\1`) and octal escapes are not supported: matching never backtracks. Capture both parts and compare them in code. A character by number is `\\x41` or `\\x{1F600}`.')
    if in_class and (c == 'b' or c == 'B' or c == 'A' or c == 'z' or c == '<' or c == '>'):
        return self.fail_at(start, 'The assertion `\\%{str.initRune(c)}` can not be in a class.')
    if is_alpha(c):
        return self.fail_at(start, 'Unknown escape `\\%{str.initRune(c)}`. To match the letter, remove the `\\`.')
    -- Punctuation and space stand for themselves.
    return c

-- `\pL`, `\p{Name}`, `\p{gc=Name}`, `\p{sc=Name}`, and `\P` for the rest. `pos` is at the backslash.
-- Adds one value to `ops`.
fn (&Builder) unicode_class() -> !void:
    start := self.pos
    negated := self.peek_at(1) == 'P'
    self.pos += 2
    var name str = ''
    if self.peek() == '{':
        close := self.src[self.pos..].index('}') ?else:
            return self.fail_at(start, 'The class `\\p{` is not closed. Add `}`.')
        name = self.src[self.pos + 1..self.pos + close]
        self.pos += close + 1
    else:
        if self.peek() == -1:
            return self.fail_at(start, 'Expected a class name after `\\p`, such as `\\pL` or `\\p{Greek}`.')
        from := self.pos
        _ = self.rune()
        name = self.src[from..self.pos]
    kind := -1
    value := name
    var sep ?int = name.index('=')
    if sep == none:
        sep = name.index(':')
    if sep |i|:
        value = name[i + 1..]
        prop_end := i
        if i > 0 and name[i - 1] == '!':
            negated = !negated
            prop_end = i - 1
        prop := loose(name[0..prop_end])
        if prop == 'gc' or prop == 'generalcategory':
            kind = 0
        else prop == 'sc' or prop == 'script':
            kind = 1
        else:
            return self.fail_at(start, 'The Unicode property `%{name[0..prop_end]}` is not supported. There are general categories (`\\p{L}`, `\\p{gc=Lu}`), scripts (`\\p{Greek}`, `\\p{sc=Hangul}`), `Alphabetic`, `Lowercase`, `Uppercase`, `White_Space`, `Any`, `ASCII` and `Assigned`.')
    key := loose(value)
    if kind == -1 and key == 'any':
        self.leaf(SetRange, 0, 0x10ffff)
    else kind == -1 and key == 'ascii':
        self.leaf(SetRange, 0, 0x7f)
    else kind == -1 and key == 'assigned':
        self.leaf(SetTable, uni_table('unassigned', 3), 0)
        self.leaf(SetNot, 0, 0)
    else:
        id := uni_table(key, kind)
        if id < 0:
            return self.fail_at(start, 'Unknown Unicode class `%{name}`. There are general categories (`\\p{L}`, `\\p{Lu}`, `\\p{Nd}`), scripts (`\\p{Greek}`, `\\p{Hangul}`), `Alphabetic`, `Lowercase`, `Uppercase`, `White_Space`, `Any`, `ASCII` and `Assigned`.')
        self.leaf(SetTable, id, 0)
    if negated:
        self.leaf(SetNot, 0, 0)

-- Adds the ranges of `[:name:]` to `ops` as one value. Returns false for an unknown name.
fn (&Builder) ascii_class(name str) -> bool:
    var r []int = {}
    if name == 'alnum':
        r = {'0', '9', 'A', 'Z', 'a', 'z'}
    else name == 'alpha':
        r = {'A', 'Z', 'a', 'z'}
    else name == 'ascii':
        r = {0, 127}
    else name == 'blank':
        r = {9, 9, 32, 32}
    else name == 'cntrl':
        r = {0, 31, 127, 127}
    else name == 'digit':
        r = {'0', '9'}
    else name == 'graph':
        r = {33, 126}
    else name == 'lower':
        r = {'a', 'z'}
    else name == 'print':
        r = {32, 126}
    else name == 'punct':
        r = {33, 47, 58, 64, 91, 96, 123, 126}
    else name == 'space':
        r = {9, 13, 32, 32}
    else name == 'upper':
        r = {'A', 'Z'}
    else name == 'word':
        r = {'0', '9', 'A', 'Z', 'a', 'z', '_', '_'}
    else name == 'xdigit':
        r = {'0', '9', 'A', 'F', 'a', 'f'}
    else:
        return false
    for 0..r.len() / 2 |i|:
        self.leaf(SetRange, r[i * 2], r[i * 2 + 1])
        if i > 0:
            self.leaf(SetOr, 0, 0)
    return true

-- A class from `[` to `]`. Adds one value to `ops`.
fn (&Builder) class_bracket() -> !void:
    open := self.pos
    self.pos += 1
    self.enter(open)!
    negated := false
    self.skip_x()
    if self.peek() == '^':
        negated = true
        self.pos += 1
        self.skip_x()
    -- At the start, `-` and one `]` stand for themselves.
    count := 0
    while self.peek() == '-':
        self.class_add(SetRange, '-', '-', count)
        count += 1
        self.pos += 1
        self.skip_x()
    if count == 0 and self.peek() == ']':
        self.class_add(SetRange, ']', ']', count)
        count += 1
        self.pos += 1
    self.class_union(open, count)!
    while:
        c := self.peek()
        op := -1
        if c == '&' and self.peek_at(1) == '&':
            op = SetAnd
        else c == '-' and self.peek_at(1) == '-':
            op = SetDiff
        else c == '~' and self.peek_at(1) == '~':
            op = SetXor
        else:
            break
        self.pos += 2
        self.class_union(open, 0)!
        self.leaf(op, 0, 0)
    if self.peek() != ']':
        return self.fail_at(open, 'This class is not closed. Add `]`, or write `\\[` to match a bracket.')
    self.pos += 1
    if negated:
        self.leaf(SetNot, 0, 0)
    self.depth -= 1

-- Adds a leaf to the union that has `count` members so far.
fn (&Builder) class_add(op int, a int, b int, count int):
    self.leaf(op, a, b)
    if count > 0:
        self.leaf(SetOr, 0, 0)

-- The members of a class up to `]` or a set operator. Adds one value to `ops`.
fn (&Builder) class_union(open int, start_count int) -> !void:
    count := start_count
    while:
        self.skip_x()
        c := self.peek()
        if c == -1:
            return self.fail_at(open, 'This class is not closed. Add `]`, or write `\\[` to match a bracket.')
        if c == ']':
            break
        c1 := self.peek_at(1)
        if (c == '&' and c1 == '&') or (c == '-' and c1 == '-') or (c == '~' and c1 == '~'):
            break
        if c == '[':
            if c1 == ':':
                if self.src[self.pos..].index(':]') |close|:
                    name := self.src[self.pos + 2..self.pos + close]
                    neg := name.starts_with('^')
                    if neg:
                        name = name[1..]
                    if !self.ascii_class(name):
                        return self.fail('Unknown class `[:%{name}:]`. There are alnum, alpha, ascii, blank, cntrl, digit, graph, lower, print, punct, space, upper, word and xdigit.')
                    if neg:
                        self.leaf(SetNot, 0, 0)
                    self.pos += close + 2
                    if count > 0:
                        self.leaf(SetOr, 0, 0)
                    count += 1
                    continue
            self.class_bracket()!
            if count > 0:
                self.leaf(SetOr, 0, 0)
            count += 1
            continue
        var lo int = 0
        if c == '\\':
            e := self.peek_at(1)
            if e == 'd' or e == 'D' or e == 's' or e == 'S' or e == 'w' or e == 'W':
                self.pos += 2
                self.perl_class(e)
                if count > 0:
                    self.leaf(SetOr, 0, 0)
                count += 1
                continue
            if e == 'p' or e == 'P':
                self.unicode_class()!
                if count > 0:
                    self.leaf(SetOr, 0, 0)
                count += 1
                continue
            start := self.pos
            self.pos += 1
            lo = self.escape_char(start, true)!
        else:
            lo = self.rune()
        hi := lo
        self.skip_x()
        if self.peek() == '-':
            after := self.peek_at(1)
            if after != -1 and after != ']' and after != '-':
                dash := self.pos
                self.pos += 1
                self.skip_x()
                if self.peek() == '\\':
                    e := self.peek_at(1)
                    if e == 'd' or e == 'D' or e == 's' or e == 'S' or e == 'w' or e == 'W' or e == 'p' or e == 'P':
                        return self.fail('A range ends with one character, not a class. Write `\\-` for a dash that is not a range.')
                    start := self.pos
                    self.pos += 1
                    hi = self.escape_char(start, true)!
                else self.peek() == '[':
                    return self.fail('A range ends with one character, not a class. Write `\\-` for a dash that is not a range.')
                else:
                    hi = self.rune()
                if hi < lo:
                    return self.fail_at(dash, 'The range %{show(lo)} to %{show(hi)} is backwards. Write `\\-` for a dash that is not a range.')
        self.class_add(SetRange, lo, hi, count)
        count += 1
    if count == 0:
        -- No members: a range that holds nothing.
        self.leaf(SetRange, 1, 0)

-- Code generation.

fn (&Builder) pc() -> int:
    return self.insts.len() / 3

fn (&Builder) emit(op int, a int, b int) -> !int:
    if self.insts.len() / 3 >= MaxInsts:
        self.msg = 'The pattern is too big: its program has more than %{MaxInsts} instructions. Lower the repetition counts.'
        self.err_pos = 0
        return error.TooBig
    self.insts = self.insts.append(op)
    self.insts = self.insts.append(a)
    self.insts = self.insts.append(b)
    return self.insts.len() / 3 - 1

-- Emits a split whose first way enters the code that follows it. Returns the split, to set its other way later.
fn (&Builder) split_enter(greedy bool) -> !int:
    s := self.emit(OpSplit, 0, 0)!
    if greedy:
        self.insts[s * 3 + 1] = s + 1
    else:
        self.insts[s * 3 + 2] = s + 1
    return s

-- Sets the way of a split that leaves, to the next instruction.
fn (&Builder) split_leave(s int, greedy bool):
    if greedy:
        self.insts[s * 3 + 2] = self.pc()
    else:
        self.insts[s * 3 + 1] = self.pc()

-- Emits a split that goes back to `top` first when greedy, and on to the next instruction otherwise.
fn (&Builder) split_back(top int, greedy bool) -> !void:
    s := self.emit(OpSplit, 0, 0)!
    if greedy:
        self.insts[s * 3 + 1] = top
        self.insts[s * 3 + 2] = s + 1
    else:
        self.insts[s * 3 + 1] = s + 1
        self.insts[s * 3 + 2] = top

fn (&Builder) gen_all(root int) -> !void:
    _ = self.emit(OpSave, 0, 0)!
    self.gen(root)!
    _ = self.emit(OpSave, 1, 0)!
    _ = self.emit(OpMatch, 0, 0)!

fn (&Builder) gen(n int) -> !void:
    self.work += 1
    if self.work > MaxInsts * 8:
        self.msg = 'The pattern is too big: it repeats too many times. Lower the repetition counts.'
        self.err_pos = 0
        return error.TooBig
    node := self.nodes[n]
    switch node.kind:
        case NEmpty:
            return
        case NChar:
            _ = self.emit(OpChar, node.a, 0)!
        case NAny:
            if node.a == 1:
                _ = self.emit(OpAnyNl, 0, 0)!
            else:
                _ = self.emit(OpAny, 0, 0)!
        case NSet:
            _ = self.emit(OpSet, node.a, 0)!
        case NAssert:
            _ = self.emit(OpAssert, node.a, 0)!
        case NCat:
            for 0..node.b |i|:
                self.gen(self.kids[node.a + i])!
        case NAlt:
            var jumps []int = {}
            for 0..node.b |i|:
                if i + 1 < node.b:
                    s := self.split_enter(true)!
                    self.gen(self.kids[node.a + i])!
                    jumps = jumps.append(self.emit(OpJmp, 0, 0)!)
                    self.split_leave(s, true)
                else:
                    self.gen(self.kids[node.a + i])!
            for jumps |j|:
                self.insts[j * 3 + 1] = self.pc()
        case NGroup:
            _ = self.emit(OpSave, node.b * 2, 0)!
            self.gen(node.a)!
            _ = self.emit(OpSave, node.b * 2 + 1, 0)!
        else:
            self.gen_repeat(node)!

fn (&Builder) gen_repeat(node Node) -> !void:
    greedy := node.d == 1
    child := node.a
    if node.c == -1:
        if node.b == 0:
            if self.nodes[child].empty:
                -- `e*` for an `e` that can match nothing is `(e+)?`, which keeps the order of the alternatives.
                s := self.split_enter(greedy)!
                top := self.pc()
                self.gen(child)!
                self.split_back(top, greedy)!
                self.split_leave(s, greedy)
            else:
                s := self.split_enter(greedy)!
                self.gen(child)!
                _ = self.emit(OpJmp, s, 0)!
                self.split_leave(s, greedy)
            return
        for 0..node.b - 1:
            self.gen(child)!
        top := self.pc()
        self.gen(child)!
        self.split_back(top, greedy)!
        return
    for 0..node.b:
        self.gen(child)!
    -- The optional rest, `(e(e)?)?`: each split leaves to the end.
    var splits []int = {}
    for 0..node.c - node.b:
        splits = splits.append(self.split_enter(greedy)!)
        self.gen(child)!
    for splits |s|:
        self.split_leave(s, greedy)

-- Appends the UTF-8 bytes of `cp`, one a word.
-fn push_utf8(out []int, cp int) -> []int:
    res := out
    if cp < 0x80:
        res = res.append(cp)
    else cp < 0x800:
        res = res.append(0xc0 || (cp >> 6))
        res = res.append(0x80 || (cp && 0x3f))
    else cp < 0x10000:
        res = res.append(0xe0 || (cp >> 12))
        res = res.append(0x80 || ((cp >> 6) && 0x3f))
        res = res.append(0x80 || (cp && 0x3f))
    else:
        res = res.append(0xf0 || (cp >> 18))
        res = res.append(0x80 || ((cp >> 12) && 0x3f))
        res = res.append(0x80 || ((cp >> 6) && 0x3f))
        res = res.append(0x80 || (cp && 0x3f))
    return res

-- Lays out the program.
fn (&Builder) assemble() -> []int:
    -- The code runs straight from the first instruction until something other than a save, an assertion
    -- or a character. The characters on the way start every match.
    var prefix []int = {}
    flags := 0
    pc := 0
    first := true
    n := self.pc()
    while pc < n:
        op := self.insts[pc * 3]
        if op == OpSave:
            pc += 1
        else op == OpAssert:
            if first and self.insts[pc * 3 + 1] == AsStartText:
                flags = FlagAnchored
            pc += 1
        else op == OpChar:
            cp := self.insts[pc * 3 + 1]
            if prefix.len() + rune_len(cp) > MaxPrefix:
                break
            prefix = push_utf8(prefix, cp)
            first = false
            pc += 1
        else:
            break
    set_base := HeaderLen + prefix.len()
    inst_base := set_base + self.sets.len()
    var prog []int = {Magic, n, self.names.len() * 2, flags, prefix.len(), HeaderLen, inst_base, 0}
    prog = prog.append(prefix.span())
    prog = prog.append(self.sets.span())
    for 0..n |i|:
        op := self.insts[i * 3]
        a := self.insts[i * 3 + 1]
        if op == OpSet:
            a += set_base
        prog = prog.append(op)
        prog = prog.append(a)
        prog = prog.append(self.insts[i * 3 + 2])
    return prog
