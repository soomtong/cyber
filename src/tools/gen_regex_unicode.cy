#!cyber

-- Writes `src/std/regex_unicode.zig`, the Unicode tables of the `regex` module, from the Unicode Character Database.
--
-- Usage: cyber src/tools/gen_regex_unicode.cy <ucd dir> <out.zig>
--
-- The directory holds these files of one UCD version (https://www.unicode.org/Public/UCD/latest/ucd/):
--   extracted/DerivedGeneralCategory.txt (as DerivedGeneralCategory.txt), Scripts.txt, DerivedCoreProperties.txt,
--   PropList.txt, CaseFolding.txt, PropertyValueAliases.txt

use os

-- A range is one int: `lo << 32 || hi`. Sorting the ints sorts the ranges.
fn range(lo int, hi int) -> int:
    return (lo << 32) || hi

fn parse_hex(s str) -> int:
    n := 0
    for 0..s.len() |i|:
        c := int(s[i])
        d := 0
        if c >= 48 and c <= 57:
            d = c - 48
        else c >= 65 and c <= 70:
            d = c - 55
        else c >= 97 and c <= 102:
            d = c - 87
        else:
            panic('Not a hex digit in `%{s}`.')
        n = n * 16 + d
    return n

fn hex(n int) -> str:
    digits := '0123456789abcdef'
    if n == 0:
        return '0x0'
    res := ''
    x := n
    while x > 0:
        res = digits[x && 15..(x && 15) + 1] + res
        x = x >> 4
    return '0x' + res

-- Returns the fields of a data line, split at `;` and trimmed. A comment or blank line has no fields.
fn fields(line str) -> []str:
    body := line
    if line.index('#') |i|:
        body = line[0..i]
    var res []str = {}
    if body.trim().len() == 0:
        return res
    for body.split(';') |f|:
        res = res.append(f.trim())
    return res

-- Lowercases and drops `_`, `-` and spaces (UAX44-LM3 loose matching, without the `is` prefix rule).
fn loose(name str) -> str:
    res := ''
    for 0..name.len() |i|:
        c := name[i]
        if c == '_' or c == '-' or c == ' ':
            continue
        res += str.init_rune(int(str.ascii_lower(c)))
    return res

-- Sorts ranges and joins the ones that touch.
fn merge(ranges []int) -> []int:
    ranges.sort()
    var res []int = {}
    for ranges |r|:
        lo := r >> 32
        hi := r && 0xffffffff
        if res.len() > 0:
            last := res[res.len() - 1]
            last_hi := last && 0xffffffff
            if lo <= last_hi + 1:
                if hi > last_hi:
                    res[res.len() - 1] = range(last >> 32, hi)
                continue
        res = res.append(range(lo, hi))
    return res

type Table:
    name   str
    ranges []int

type Tables:
    list []Table = {}

fn (&Tables) find(name str) -> ?int:
    for 0..self.list.len() |i|:
        if self.list[i].name == name:
            return i
    return none

fn (&Tables) add(name str, r int):
    if self.find(name) |i|:
        self.list[i].ranges = self.list[i].ranges.append(r)
    else:
        self.list = self.list.append(Table{name=name, ranges={r}})

fn (&Tables) get(name str) -> []int:
    i := self.find(name) ?else panic('No table `%{name}`.')
    return self.list[i].ranges

-- Reads a `range ; value` file. `only` keeps the listed values, or all of them when it is empty.
fn read_props(path str, only []str) -> !Tables:
    src := os.read_file(path)!
    var res Tables = {}
    for src.split('\n') |line|:
        f := fields(line)
        if f.len() < 2:
            continue
        if only.len() > 0 and !only.contains(f[1]):
            continue
        lo := 0
        hi := 0
        if f[0].index('..') |i|:
            lo = parse_hex(f[0][0..i])
            hi = parse_hex(f[0][i + 2..])
        else:
            lo = parse_hex(f[0])
            hi = lo
        res.add(f[1], range(lo, hi))
    for 0..res.list.len() |i|:
        res.list[i].ranges = merge(res.list[i].ranges)
    return res

fn union_of(t &Tables, names []str) -> []int:
    var all []int = {}
    for names |n|:
        for t.get(n) |r|:
            all = all.append(r)
    return merge(all)

type Name:
    name  str
    kind  int
    table int

args := os.args()
if args.len() < 3:
    panic('Usage: cyber src/tools/gen_regex_unicode.cy <ucd dir> <out.zig>')
dir := args[1]
out_path := args[2]

gc := read_props(dir + '/DerivedGeneralCategory.txt', {})!
sc := read_props(dir + '/Scripts.txt', {})!
core := read_props(dir + '/DerivedCoreProperties.txt', {'Alphabetic', 'Lowercase', 'Uppercase'})!
prop := read_props(dir + '/PropList.txt', {'White_Space', 'Join_Control'})!

-- The UCD version, from the first line: `# DerivedGeneralCategory-18.0.0.txt`.
head := os.read_file(dir + '/DerivedGeneralCategory.txt')!
first := head[0..head.index('\n').?]
version := first[first.index('-').? + 1..first.index('.txt').?]

var tables []Table = {}
var names []Name = {}

-- General categories and their groups. Kind 0.
groups := []str{'L', 'LC', 'M', 'N', 'P', 'S', 'Z', 'C'}
members := [][]str{
    {'Lu', 'Ll', 'Lt', 'Lm', 'Lo'},
    {'Lu', 'Ll', 'Lt'},
    {'Mn', 'Mc', 'Me'},
    {'Nd', 'Nl', 'No'},
    {'Pc', 'Pd', 'Ps', 'Pe', 'Pi', 'Pf', 'Po'},
    {'Sm', 'Sc', 'Sk', 'So'},
    {'Zs', 'Zl', 'Zp'},
    {'Cc', 'Cf', 'Cs', 'Co', 'Cn'},
}
for gc.list |t|:
    tables = tables.append(t)
for 0..groups.len() |i|:
    tables = tables.append(Table{name=groups[i], ranges=union_of(&gc, members[i])})
gc_end := tables.len()

-- Scripts. Kind 1.
for sc.list |t|:
    tables = tables.append(t)
sc_end := tables.len()

-- Binary properties. Kind 2.
bin_names := []str{'Alphabetic', 'Lowercase', 'Uppercase', 'White_Space'}
bin_aliases := []str{'Alpha', 'Lower', 'Upper', 'space'}
tables = tables.append(Table{name='Alphabetic', ranges=core.get('Alphabetic')})
tables = tables.append(Table{name='Lowercase', ranges=core.get('Lowercase')})
tables = tables.append(Table{name='Uppercase', ranges=core.get('Uppercase')})
tables = tables.append(Table{name='White_Space', ranges=prop.get('White_Space')})

-- `\w`: Alphabetic + M + Nd + Pc + Join_Control, as in the Rust `regex` crate (UTS#18 Annex C).
var word []int = {}
for core.get('Alphabetic') |r|:
    word = word.append(r)
for union_of(&gc, {'Mn', 'Mc', 'Me', 'Nd', 'Pc'}) |r|:
    word = word.append(r)
for prop.get('Join_Control') |r|:
    word = word.append(r)
word_id := tables.len()
tables = tables.append(Table{name='word', ranges=merge(word)})

fn table_id(tables []Table, from int, to int, name str) -> ?int:
    for from..to |i|:
        if tables[i].name == name:
            return i
    return none

-- Names: the table's own name and the aliases of PropertyValueAliases.txt.
for 0..tables.len() - 1 |i|:
    kind := 2
    if i < gc_end:
        kind = 0
    else i < sc_end:
        kind = 1
    names = names.append(Name{name=loose(tables[i].name), kind=kind, table=i})
for 0..bin_names.len() |i|:
    names = names.append(Name{name=loose(bin_aliases[i]), kind=2, table=table_id(tables, sc_end, tables.len(), bin_names[i]).?})
names = names.append(Name{name='wspace', kind=2, table=table_id(tables, sc_end, tables.len(), 'White_Space').?})

aliases := os.read_file(dir + '/PropertyValueAliases.txt')!
for aliases.split('\n') |line|:
    f := fields(line)
    if f.len() < 3:
        continue
    var id ?int = none
    kind := 0
    if f[0] == 'gc':
        id = table_id(tables, 0, gc_end, f[1])
    else f[0] == 'sc':
        kind = 1
        -- The table has the long name (`Greek`), the short one comes first (`Grek`).
        id = table_id(tables, gc_end, sc_end, f[2])
    else:
        continue
    if id |t|:
        for 1..f.len() |k|:
            n := loose(f[k])
            dup := false
            for names |e|:
                if e.name == n and e.kind == kind:
                    dup = true
                    break
            if !dup:
                names = names.append(Name{name=n, kind=kind, table=t})

-- Simple case folding (statuses C and S). Each code point of an orbit points to the next larger one, the largest to
-- the smallest (as Go's `unicode.SimpleFold`).
fold_src := os.read_file(dir + '/CaseFolding.txt')!
var pairs []int = {}      -- target << 32 || code point
for fold_src.split('\n') |line|:
    f := fields(line)
    if f.len() < 3:
        continue
    if f[1] != 'C' and f[1] != 'S':
        continue
    cp := parse_hex(f[0])
    target := parse_hex(f[2])
    pairs = pairs.append(range(target, cp))
    pairs = pairs.append(range(target, target))
pairs.sort()
var fold []int = {}       -- code point << 32 || next
i := 0
while i < pairs.len():
    target := pairs[i] >> 32
    j := i
    var orbit []int = {}
    while j < pairs.len() and pairs[j] >> 32 == target:
        cp := pairs[j] && 0xffffffff
        if orbit.len() == 0 or orbit[orbit.len() - 1] != cp:
            orbit = orbit.append(cp)
        j += 1
    for 0..orbit.len() |k|:
        fold = fold.append(range(orbit[k], orbit[(k + 1) % orbit.len()]))
    i = j
fold.sort()

-- Output.
var out []str = {}
out = out.append('// Generated by src/tools/gen_regex_unicode.cy from the Unicode Character Database %{version}. Do not edit.\n')
out = out.append('// The data is derived from the Unicode Data Files, Copyright (c) Unicode, Inc., under the Unicode License v3\n')
out = out.append('// (https://www.unicode.org/license.txt).\n')
out = out.append('\n/// An inclusive range of code points.\npub const R = [2]u32;\n')
out = out.append('\npub const version = "%{version}";\n')
out = out.append('\n/// Table ids of the Perl classes.\npub const word: u16 = %{word_id};\n')
out = out.append('pub const digit: u16 = %{table_id(tables, 0, gc_end, 'Nd').?};\n')
out = out.append('pub const space: u16 = %{table_id(tables, sc_end, tables.len(), 'White_Space').?};\n')
out = out.append('pub const unassigned: u16 = %{table_id(tables, 0, gc_end, 'Cn').?};\n')

out = out.append('\n/// A property value name in loose form (lower case, without `_`, `-` and spaces).\n')
out = out.append('/// `kind`: 0 general category, 1 script, 2 binary property.\n')
out = out.append('pub const Name = struct { name: []const u8, kind: u8, table: u16 };\n')
out = out.append('\npub const names = [_]Name{\n')
for names |n|:
    out = out.append('    .{ .name = "%{n.name}", .kind = %{n.kind}, .table = %{n.table} },\n')
out = out.append('};\n')

out = out.append('\npub const tables = [_][]const R{\n')
for 0..tables.len() |t|:
    out = out.append('    &t%{t}, // %{tables[t].name}\n')
out = out.append('};\n')

total := 0
for 0..tables.len() |t|:
    out = out.append('\nconst t%{t} = [_]R{')
    rs := tables[t].ranges
    total += rs.len()
    for 0..rs.len() |k|:
        if k % 8 == 0:
            out = out.append('\n   ')
        out = out.append(' .{ %{hex(rs[k] >> 32)}, %{hex(rs[k] && 0xffffffff)} },')
    out = out.append('\n};\n')

out = out.append('\n/// Simple case folding orbits, sorted by code point: `{ c, next }`, where `next` is the next larger code point\n')
out = out.append('/// that folds to the same one, or the smallest when `c` is the largest.\n')
out = out.append('pub const fold = [_]R{')
for 0..fold.len() |k|:
    if k % 8 == 0:
        out = out.append('\n   ')
    out = out.append(' .{ %{hex(fold[k] >> 32)}, %{hex(fold[k] && 0xffffffff)} },')
out = out.append('\n};\n')

os.write_file(out_path, out.join(''))!
print('UCD %{version}: %{tables.len()} tables, %{total} ranges, %{names.len()} names, %{fold.len()} fold entries')
