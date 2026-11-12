use t 'test'

-- Single quote literal.
s := 'abc🦊xyz🐶'
t.eq(s, 'abc🦊xyz🐶')

-- rune_at()
t.eq(s.rune_at(s.seek_pos(0)), 'a')
t.eq(s.rune_at(s.seek_pos(3)), '🦊')
t.eq(s.rune_at(s.seek_pos(7)), '🐶')

-- slice operator
t.eq(s[0..1].isAscii(), true)
t.eq(s[3..4].isAscii(), false)
t.eq(s[s.seek_pos(0)..], 'abc🦊xyz🐶')
t.eq(s[s.seek_pos(4)..], 'xyz🐶')
t.eq(s[s.seek_pos(7)..], '🐶')
t.eq(s[s.seek_pos(8)..], '')
t.eq(s[0..0], '')
t.eq(s[0..s.seek_pos(4)], 'abc🦊')
t.eq(s[0..s.seek_pos(7)], 'abc🦊xyz')
t.eq(s[0..s.seek_pos(8)], 'abc🦊xyz🐶')
t.eq(s[0..0], '')
t.eq(s[0..s.seek_pos(1)], 'a')
t.eq(s[s.seek_pos(4)..s.seek_pos(8)], 'xyz🐶')
t.eq(s[s.seek_pos(7)..s.seek_pos(8)], '🐶')
t.eq(s[s.seek_pos(8)..s.seek_pos(8)], '')

-- concat()
t.eq(s.concat('123'), 'abc🦊xyz🐶123')

-- count()
t.eq(s.count(), 8)

-- ends_with()
t.eq(s.ends_with('xyz🐶'), true)
t.eq(s.ends_with('xyz'), false)

-- index(str)
t.eq(s.index('bc🦊').?, 1)
t.eq(s.index('xy').?, 7)
t.assert(s.index('bd') == none)
t.eq(s.index('ab').?, 0)

-- index_any_rune([]int)
t.eq(0, s.index_any_rune({'a'}).?)
t.eq(3, s.index_any_rune({'🦊'}).?)        -- Find utf-8 rune.
t.eq(0, s.index_any_rune({'🦊', 'a'}).?)   -- Find ascii rune.
t.eq(7, s.index_any_rune({'x', 'y'}).?)
t.assert(s.index_any_rune({'e', 'f'}) == none)

-- index_rune
t.eq(s.index_rune('a').?, 0)
t.eq(s.index_rune('🦊').?, 3)
t.eq(s.index_rune('x').?, 7)
t.assert(s.index_rune('d') == none)
t.eq(s.index_rune(97).?, 0)
t.eq(s.index_rune(129418).?, 3)
t.eq(s.index_rune(128054).?, 10)
t.assert(s.index_rune(100) == none)

-- insert()
t.eq(s.insert(s.seek_pos(0), 'foo'), 'fooabc🦊xyz🐶')
t.eq(s.insert(s.seek_pos(3), 'foo🦊'), 'abcfoo🦊🦊xyz🐶')
t.eq(s.insert(s.seek_pos(7), 'foo'), 'abc🦊xyzfoo🐶')
t.eq(s.insert(s.seek_pos(8), 'foo'), 'abc🦊xyz🐶foo')

-- isAscii()
t.eq(s.isAscii(), false)

-- len()
t.eq(s.len(), 14)

-- less()
t.eq(s.less('ac'), true)
t.eq(s.less('aa'), false)

-- lower()
t.eq('AB🦊C'.lower(), 'ab🦊c')

-- repeat()
t.eq(s.repeat(0), '')
t.eq(s.repeat(0).isAscii(), true)
t.eq(s.repeat(1), 'abc🦊xyz🐶')
t.eq(s.repeat(1).isAscii(), false)
t.eq(s.repeat(2), 'abc🦊xyz🐶abc🦊xyz🐶')
t.eq(s.repeat(2).isAscii(), false)

-- replace()
t.eq(s.replace('abc🦊', 'foo'), 'fooxyz🐶')
t.eq(s.replace('bc🦊', 'foo'), 'afooxyz🐶')
t.eq(s.replace('bc', 'foo🦊'), 'afoo🦊🦊xyz🐶')
t.eq(s.replace('xy', 'foo'), 'abc🦊fooz🐶')
t.eq(s.replace('xyz🐶', 'foo'), 'abc🦊foo')
t.eq(s.replace('abcd', 'foo'), 'abc🦊xyz🐶')

-- runeStrAt().
t.eq(s.runeStrAt(0), 'a')
t.eq(s.runeStrAt(0).isAscii(), true)
t.eq(s.runeStrAt(s.seek_pos(3)), '🦊')
t.eq(s.runeStrAt(s.seek_pos(3)).isAscii(), false)
t.eq(s.runeStrAt(s.seek_pos(7)), '🐶')

-- split()
res := 'abc,🐶ab,a'.split(',')
t.eq(res.len(), 3)
t.eq(res[0], 'abc')
t.eq(res[1], '🐶ab')
t.eq(res[2], 'a')

-- starts_with()
t.eq(s.starts_with('abc🦊'), true)
t.eq(s.starts_with('bc🦊'), false)

-- trim()
t.eq(s.trimLeft('a'), 'bc🦊xyz🐶')
t.eq(s.trimRight('🐶'), 'abc🦊xyz')
t.eq(s.trim({'a', '🐶'}), 'bc🦊xyz')
-- Several delimiters are trimmed in any order, until none is left at that end.
t.eq('abc  \r'.trimRight({' ', '\r', '\t'}), 'abc')
t.eq(' \t abc'.trimLeft({'\t', ' '}), 'abc')
t.eq('x cabcx c'.trim({'x', 'c', ' '}), 'ab')
-- An empty delimiter trims nothing.
t.eq('abc'.trim(''), 'abc')
t.eq('abc'.trimLeft({'', 'a'}), 'bc')

-- upper()
t.eq(s.upper(), 'ABC🦊XYZ🐶')

-- from_utf8() validates, str(bytes) does not.
t.eq(str.from_utf8('abc🦊'.span()) !else 'bad', 'abc🦊')
t.eq(str.from_utf8([]byte{104, 105}) !else 'bad', 'hi')
t.eq(str.from_utf8([]byte{}) !else 'bad', '')
t.eq(str.from_utf8([]byte{0xff, 0x61}) !else 'bad', 'bad')
t.eq(str.from_utf8([]byte{0xf0, 0x9f, 0xa6}) !else 'bad', 'bad')
t.eq(str.is_utf8([]byte{0xf0, 0x9f, 0xa6, 0x8a}.span()), true)
t.eq(str.is_utf8([]byte{0xc0, 0x80}.span()), false)
t.eq(str([]byte{0xff, 0x61}).len(), 2)

--cytest: pass