use t 'test'
use meta

-- TODO: All string tests will be separated to strings_ascii and strings_utf8.

escaped := 'Return the underlying `symbol`.'.replace('`', `\\`)
t.eq(escaped, `Return the underlying \\symbol\\.`)

-- Raw string does not interpret escape characters.
a := `\n`
t.eq(2, a.len())
t.assert(a[0] == '\\')
t.assert(a[1] == 'n')

-- Indexing.
s := 'abc🦊xyz🐶'
t.eq(s[0], 97)
t.eq(s[3], 240)
t.eq(s[4], 159)
t.eq(s[10], 240)
t.eq(s[13], 182)

-- iterator.
iter := s.iterator()
t.eq(s.next(&iter), byte(97))

-- -- decode()
-- t.eq(arr.decode(), 'abc🦊xyz🐶')
-- t.eq(arr.decode().isAscii(), false)
-- t.eq(Array('abc').decode(), 'abc')
-- t.eq(Array('abc').decode().isAscii(), true)
-- t.eq(try Array('').insertByte(0, 255).decode(), error.Unicode)

-- -- fmt()
-- t.eq('{}'.fmt({^1}), '1')
-- t.eq('{}, {}'.fmt({^1, ^2}), '1, 2')
-- t.eq('$PH'.fmt('$PH', {^1}), '1')
-- t.eq('$PH, $PH'.fmt('$PH', {^1, ^2}), '1, 2')

-- fmt_bytes()
t.eq('172', 'z'.fmt_bytes(.oct))
t.eq('122', 'z'.fmt_bytes(.dec))
t.eq('7a', 'z'.fmt_bytes(.hex))
if meta.is_vm_target():
    t.eq('01111010', 'z'.fmt_bytes(.bin))
    t.eq('0110000101100010011000111111000010011111101001101000101001111000011110010111101011110000100111111001000010110110', s.fmt_bytes(.bin))
    t.eq('141142143360237246212170171172360237220266', s.fmt_bytes(.oct))
    t.eq('097098099240159166138120121122240159144182', s.fmt_bytes(.dec))
    t.eq('616263f09fa68a78797af09f90b6', s.fmt_bytes(.hex))

-- Escape sequences.
esc := 'a\0b\x41\t\\|'
t.eq(7, esc.len())
t.eq(0, esc[1])
t.eq(0x41, esc[3])
t.eq(9, esc[4])
t.eq(0x5c, esc[5])
var nul byte = '\0'
t.eq(0, nul)

-- rune_at()
invalid := "\xc3\x28"
t.eq(2, invalid.len())
t.eq(1, invalid.count())
t.eq(0xFFFD, invalid.rune_at(0))

-- insert(byte)
t.eq('abac🦊xyz🐶', s.insert(2, 97))

-- $init()
s2 := 'abcd'
t.eq(str(s2), 'abcd')
t.eq(str(s2[0..2]), 'ab')
t.eq(str(123), '123')
t.eq(str(123.4), '123.4')
t.eq(str(123.456), '123.456')
t.eq(str(123.00000123), '123.00000123')
t.eq(str(int(123)), '123')
t.eq(str(error.foo), 'error.foo')
t.eq(str(symbol.foo), 'symbol.foo')

-- initRune(int)
if meta.is_vm_target():
    t.eq(str.initRune('a'), 'a')
    t.eq(str.initRune('🦊'), '🦊')
    -- t.eq(try runestr(2 ^ 22), error.InvalidRune)
    -- t.eq(try runestr(-1), error.InvalidRune)

-- str.is_ascii_alpha()
t.eq(false, str.is_ascii_alpha('3'))
t.eq(true, str.is_ascii_alpha('a'))
t.eq(true, str.is_ascii_alpha('A'))

-- str.is_ascii_digit()
t.eq(true, str.is_ascii_digit('3'))
t.eq(false, str.is_ascii_digit('a'))
t.eq(false, str.is_ascii_digit('A'))

-- index_rune() with a value that is not a code point. Aborted the host for a value above 21 bits.
t.eq(true, 'abc'.index_rune(1 << 62) == none)
t.eq(true, 'abc'.index_rune(0x110000) == none)
t.eq(true, 'abc'.index_rune(-1) == none)
t.eq(1, 'abc'.index_rune(98).?)
t.eq(6, 'ab'.repeat(3).len())

-- Comparison operators compare the bytes, like `compare`.
t.eq('a' < 'b', true)
t.eq('b' < 'a', false)
t.eq('a' < 'ab', true)
t.eq('a' <= 'a', true)
t.eq('b' <= 'a', false)
t.eq('ab' > 'a', true)
t.eq('a' >= 'a', true)
t.eq('a' >= 'b', false)

--cytest: pass