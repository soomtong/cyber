use regex
use t 'test'

-- The matches of `pat` in `s` as text: `0-3 5-6`.
fn spans(pat str, s str) -> str:
    re := regex.compile(pat) !else:
        return 'error'
    out := ''
    for re.find_all(s) |m|:
        if out.len() > 0:
            out += ' '
        out += '%{m.start}-%{m.end}'
    return out

-- The message and position of a pattern that does not compile.
fn err_of(pat str) -> str:
    var diag regex.Diag = {}
    try:
        _ = regex.compile(pat, &diag)!
    else |err|:
        return '%{err} %{diag.pos}: %{diag.msg}'
    return 'ok'

fn fails(pat str) -> bool:
    _ = regex.compile(pat) !else:
        return true
    return false

-- Searching.
re := regex.compile(`(?P<key>\w+)=(\d+)`)!
line := 'retries=3 timeout=250'
t.eq(true, re.is_match(line))
t.eq(false, re.is_match('no pairs here'))
m := re.find(line).?
t.eq(0, m.start)
t.eq(9, m.end)
t.eq('retries=3', m.text)
t.eq('es=3', re.find(line, 5).?.text)
t.eq('timeout=250', re.find(line, 9).?.text)
t.eq(true, re.find(line, 18) == none)
t.eq(true, re.find(line, 99) == none)
t.eq(true, re.find(line, -1) == none)
all := re.find_all(line)
t.eq(2, all.len())
t.eq('timeout=250', all[1].text)
t.eq(10, all[1].start)
t.eq(0, re.find_all('').len())

-- Groups.
c := re.captures(line).?
t.eq(3, c.len())
t.eq('retries=3', c[0])
t.eq('retries', c[1])
t.eq('3', c[2])
t.eq('retries', c['key'])
t.eq(8, c.get(2).?.start)
t.eq(9, c.get(2).?.end)
t.eq('retries', c.get('key').?.text)
t.eq(true, c.get(3) == none)
t.eq(true, c.get(-1) == none)
t.eq(true, c.get('nope') == none)
t.eq('250', re.captures(line, 9).?[2])
t.eq(true, re.captures('x') == none)
cs := re.captures_all(line)
t.eq(2, cs.len())
t.eq('timeout', cs[1]['key'])
t.eq('250', cs[1][2])
t.eq(3, re.captures_len())
t.eq('key', re.capture_names()[1])
t.eq('', re.capture_names()[0])
t.eq('', re.capture_names()[2])
t.eq(`(?P<key>\w+)=(\d+)`, re.pattern())

-- A group that did not take part is `none`, and `''` by index.
opt := regex.compile(`(a)|(b)`)!.captures('b').?
t.eq(true, opt.get(1) == none)
t.eq('', opt[1])
t.eq('b', opt[2])
-- A repeated group keeps its last round.
t.eq('c', regex.compile(`(?:(\w),?)+`)!.captures('a,b,c').?[1])
t.eq('n', regex.compile(`(?<n>.)`)!.capture_names()[1])

-- Replacing.
t.eq('3=retries 250=timeout', re.replace_all(line, '$2=$key'))
t.eq('3=retries timeout=250', re.replace(line, '${2}=${key}'))
t.eq('[retries=3] [timeout=250]', re.replace_all(line, '[$0]'))
t.eq('X X', re.replace_all(line, 'X'))
t.eq('X timeout=250', re.replace(line, 'X'))
t.eq('$ $', re.replace_all(line, '$$'))
t.eq('3a 250a', re.replace_all(line, '${2}a'))
-- `$2a` is the group named `2a`, which does not exist.
t.eq(' ', re.replace_all(line, '$2a'))
t.eq('$ $', re.replace_all(line, '$'))
t.eq('${2 ${2', re.replace_all(line, '${2'))
t.eq('- -', re.replace_all(line, '$nope-$9'))
t.eq('no match', re.replace_all('no match', '$1'))
t.eq('no match', re.replace('no match', '$1'))
t.eq('a-b-c', regex.compile(`\s+`)!.replace_all('a  b \t c', '-'))
t.eq('-a-b-', regex.compile(`x*`)!.replace_all('ab', '-'))
t.eq('3:retries', c.expand('$2:$1'))

-- Splitting.
ws := regex.compile(`[,;]\s*`)!
t.eq('a|b|c', ws.split('a, b;c').join('|'))
t.eq('a|b;c', ws.split('a, b;c', 2).join('|'))
t.eq('a, b;c', ws.split('a, b;c', 1).join('|'))
t.eq(0, ws.split('a, b;c', 0).len())
t.eq('|a|', ws.split(',a,').join('|'))
t.eq('abc', ws.split('abc').join('|'))
t.eq(1, ws.split('').len())
t.eq('|a|b|', regex.compile('')!.split('ab').join('|'))
-- Groups are not part of the pieces.
t.eq('a|b', regex.compile(`(,)`)!.split('a,b').join('|'))

-- Escaping.
t.eq(`a\.b\*c\[d\]\(e\)\{f\}\^\$\|\?\+\\\-\#\&\~`, regex.escape('a.b*c[d](e){f}^$|?+\\-#&~'))
t.eq('abc 가', regex.escape('abc 가'))
t.eq('0-5', spans(regex.escape('a.b*c'), 'a.b*c axbc'))

-- The first alternative that matches wins, not the longest.
t.eq('0-3', spans(`sam|samwise`, 'samwise'))
t.eq('0-7', spans(`samwise|sam`, 'samwise'))
t.eq('0-4', spans(`(?:a|ab)(?:c|bcd)`, 'abcd'))
-- Greedy and lazy.
t.eq('0-6', spans(`<.+>`, '<a><b>'))
t.eq('0-3 3-6', spans(`<.+?>`, '<a><b>'))
t.eq('0-2 2-4', spans(`a{2,3}?`, 'aaaa'))
t.eq('2-4 5-8 9-12', spans(`a{2,3}`, 'a aa aaa aaaa'))
t.eq('0-1 1-2 2-3', spans(`(?U)a+`, 'aaa'))
t.eq('0-3', spans(`(?U)a+?`, 'aaa'))
t.eq('0-4', spans(`a{2}{2}`, 'aaaaa'))
t.eq('0-3 4-4', spans(`a?+`, 'aaab'))
t.eq('0-0', spans(`a{0}`, ''))
-- An empty match that touches the match before it is left out.
t.eq('0-0 1-4 5-5', spans(`a*`, 'baaac'))
t.eq('0-0 1-1 2-2', spans(``, 'ab'))
t.eq('0-0 1-2', spans(`a|`, 'ba'))
t.eq('0-0 1-1', spans(`(a*)*`, 'b'))
-- An empty match does not fall inside a code point.
t.eq('0-0 4-5', spans(`x*`, '😀x'))
t.eq('0-0 3-3', spans(``, '가'))

-- Anchors and flags.
t.eq('', spans(`^\d+$`, '12\n34'))
t.eq('0-2 3-5', spans(`(?m)^\d+$`, '12\n34\nx5'))
t.eq('0-1', spans(`\A\d`, '12'))
t.eq('1-2', spans(`\d\z`, '12'))
t.eq('', spans(`\d$`, '12\n'))
t.eq('0-1 2-3', spans(`.`, 'a\nb'))
t.eq('0-1 1-2 2-3', spans(`(?s).`, 'a\nb'))
t.eq('0-3 4-7', spans(`(?i)abc`, 'ABC aBc'))
t.eq('0-1', spans(`(?i)a(?-i)b|A`, 'AB'))
t.eq('0-2 3-4', spans(`a(?i)b|c`, 'aB C'))
t.eq('0-2', spans(`(?i:a)b`, 'Ab AB'))
t.eq('2-6', spans('(?x) \\d+ # digits\n  \\. \\d+', 'v 3.14'))
t.eq('0-4', spans(`(?x) a\ b [\ ]`, 'a b '))
-- White space is skipped inside a class too, which leaves this one empty.
t.eq(true, fails(`(?x)[ ]`))
t.eq('0-2', spans(`(?is-m)A.`, 'a\n'))
t.eq('0-2', spans(`(?u)\w+`, 'ab'))

-- Unicode: classes, word boundaries and case folding go by code point.
t.eq('0-6 7-13 14-20 21-23', spans(`\w+`, '한글 로그 line_1 é'))
t.eq('0-3 7-10', spans(`\b\w`, '가나 다라'))
t.eq('0-6', spans(`\d+`, '٣٤٥'))
t.eq('1-4', spans(`\s`, 'a' + str.initRune(0x3000) + 'b'))
t.eq('4-10', spans(`\p{Hangul}+`, 'abc 한글 def'))
t.eq('4-10', spans(`\p{sc=Hang}+`, 'abc 한글 def'))
t.eq('0-5 6-11 18-23', spans(`\p{Lu}\p{Ll}+`, 'Hello World élan Élan'))
t.eq('0-5 6-11 18-23', spans(`\p{gc=Uppercase_Letter}\p{general_category:lowercase letter}+`, 'Hello World élan Élan'))
t.eq('0-1 2-4', spans(`\pL`, 'a1é'))
t.eq('1-2', spans(`\PL`, 'a1é'))
t.eq('1-2', spans(`\p{gc!=L}`, 'a1é'))
t.eq('0-4', spans(`\p{Any}+`, 'a1é'))
t.eq('0-2', spans(`\p{ASCII}+`, 'a1é'))
t.eq('2-4', spans(`\P{ascii}+`, 'a1é'))
t.eq('0-1', spans(`\p{Assigned}`, 'a' + str.initRune(0x378)))
t.eq('0-2 3-4', spans(`\p{Alphabetic}+`, 'ab1c'))
t.eq('0-1', spans(`\p{White_Space}`, ' a'))
t.eq('0-7 8-9 10-11 12-15', spans(`(?i)strasse|k`, 'STRASSE k K ' + str.initRune(0x212a)))
t.eq('0-2', spans(`(?i)s`, str.initRune(0x17f)))
t.eq('0-2 2-4 4-6', spans(`(?i)σ`, 'Σσς'))
t.eq('0-2 3-5', spans(`(?i)é`, 'É é'))
t.eq('0-2', spans(`(?i)\p{Lu}+`, 'aB1'))
t.eq('2-3', spans(`(?i)[^k]`, 'kKx' + str.initRune(0x212a)))
t.eq('0-1', spans(`\x41`, 'A'))
t.eq('0-7', spans(`\x41é\x{1F600}`, 'Aé😀'))
t.eq('0-6', spans(`\U0001F600\u{e9}`, '😀é'))
t.eq('0-3 3-4 4-7', spans(`.`, '가 나'))
t.eq('0-4', spans(`[^a]`, '😀a'))

-- Classes.
t.eq('3-7', spans(`[^a-c]+`, 'abcdéf'))
t.eq('0-1 2-3', spans(`[]a]`, ']ba'))
t.eq('0-1 1-2', spans(`[^]a]`, 'bc]a'))
t.eq('0-1 2-3', spans(`[a-]`, 'a.-'))
t.eq('0-1 2-3', spans(`[-a]`, 'a.-'))
t.eq('0-1 1-2 2-3', spans(`[a\-z]`, 'a-zb'))
t.eq('0-3', spans(`[\d\s]+`, '1 2x'))
t.eq('0-2', spans(`[\w--\d]+`, 'ab12'))
t.eq('1-2 3-4 5-6 8-9', spans(`[[:alpha:]&&[^aeiou]]+`, 'education'))
t.eq('1-2 3-4 5-6 8-9', spans(`[a-z--[aeiou]]+`, 'education'))
t.eq('0-1 3-4', spans(`[a-c~~b-d]`, 'abcd'))
t.eq('0-2', spans(`[a[b]]+`, 'abc'))
t.eq('2-3', spans(`[^a[b]]`, 'abc'))
t.eq('0-1', spans(`[a&b]`, '&'))
t.eq('', spans(`[a&&b]`, 'ab'))
t.eq('0-3', spans(`[[:digit:][:^alpha:]]+`, '1 2a'))
t.eq('0-1 2-3', spans(`[[:upper:]]`, 'AbC'))
t.eq('0-3', spans(`(?i)[[:upper:]]+`, 'AbC'))
t.eq('0-1', spans(`[\x41-\x{42}]`, 'AC'))
t.eq('0-3', spans(`[가-힣]`, '한a'))
t.eq('1-2', spans(`(?x)[ a b ]`, ' a'))
t.eq('0-1', spans(`[\]]`, ']'))
t.eq('0-1', spans(`[\n]`, '\n'))

-- Word boundaries.
t.eq('0-3 14-17', spans(`\bfoo\b`, 'foo food afoo foo'))
t.eq('5-8', spans(`\Bfoo`, 'foo afoo'))
t.eq('0-2 3-5', spans(`\b{start}\w+`, 'ab cd'))
t.eq('0-2 3-5', spans(`\<\w+\>`, 'ab cd'))
t.eq('1-2 4-5', spans(`\w\b{end}`, 'ab cd'))
t.eq('0-1 2-3', spans(`\b{start-half}a`, 'a aa'))
t.eq('1-2', spans(`a\b{end-half}`, 'aa'))
t.eq('0-0 1-1', spans(`\b{2}`, 'a'))

-- Bytes that are not UTF-8 match no class, not even `.` or a negated class, and searching goes on after them.
bad := str([]byte{'a', 0xff, 'b', 0xea, 0xb0, 'c'})
t.eq('0-1 2-3 5-6', spans(`.`, bad))
t.eq('2-3 5-6', spans(`[^a]`, bad))
t.eq('0-1 2-3 5-6', spans(`\w+`, bad))
t.eq(false, regex.compile(`a.b`)!.is_match(bad))
-- A search that starts inside a code point starts after it.
t.eq(4, regex.compile(``)!.find('😀', 1).?.start)
t.eq(3, regex.compile(`.`)!.find('가나', 1).?.start)

-- A literal prefix and `\A` take a short way in the search. The answers are the same.
t.eq('', spans(`abc`, 'ab'))
t.eq('', spans(`abc`, ''))
t.eq('2-5 7-10', spans(`abc\d*`, 'ababc  abc'))
t.eq('1-2', spans(`b`, 'abc'))
t.eq('3-6', spans(`가+`, 'a b가'))
t.eq('0-1', spans(`\Aa`, 'aaa'))
t.eq('', spans(`\Ab`, 'ab'))
t.eq('0-2 2-4', spans(`(?:ab)+?`, 'abab'))
t.eq('5-8', spans(`\babc`, 'xabc abc'))
long := 'x' ** 70
t.eq('1-71', spans(long, 'y' + long))

-- What is not supported says so, and what to write instead.
t.eq('error.Syntax 1: Look-ahead (`(?=...)`, `(?!...)`) is not supported: matching never backtracks. Match the text that follows as part of the pattern and take the part you need with a group.', err_of('a(?=b)'))
t.eq(true, err_of('(?!a)').starts_with('error.Syntax 0: Look-ahead'))
t.eq(true, err_of('(?<=a)b').starts_with('error.Syntax 0: Look-behind'))
t.eq(true, err_of('(?<!a)b').starts_with('error.Syntax 0: Look-behind'))
t.eq(true, err_of('(?>a)').starts_with('error.Syntax 0: Atomic groups'))
t.eq(true, err_of('(a)\\1').starts_with('error.Syntax 3: Backreferences'))
t.eq(true, err_of('(?P<n>a)(?P=n)').starts_with('error.Syntax 8: Backreferences'))
t.eq('error.Syntax 1: `\\Z` is not supported. The end of the input is `\\z`. Before an optional last line feed, write `\\n?\\z`.', err_of('a\\Z'))
t.eq(true, err_of('(?-u)a').starts_with('error.Syntax 3: The `u` flag can not be turned off'))
t.eq(true, err_of('(?R)a').starts_with('error.Syntax 2: The `R` flag'))
t.eq(true, err_of('(?a)x').starts_with('error.Syntax 2: The flag `a` is Python'))
t.eq(true, err_of('\\p{Emoji}').starts_with('error.Syntax 0: Unknown Unicode class `Emoji`.'))
t.eq(true, err_of('\\p{scx=Greek}').starts_with('error.Syntax 0: The Unicode property `scx` is not supported.'))
t.eq(true, err_of('\\p{^L}').starts_with('error.Syntax 0: Unknown Unicode class'))
t.eq(true, err_of('(?#c)a').starts_with('error.Syntax 0: Comment groups'))

-- Malformed patterns.
t.eq('error.Syntax 0: This group is not closed. Add `)`, or write `\\(` to match a parenthesis.', err_of('(a'))
t.eq('error.Syntax 1: This `)` closes no group. Write `\\)` to match a parenthesis.', err_of('a)'))
t.eq('error.Syntax 0: This class is not closed. Add `]`, or write `\\[` to match a bracket.', err_of('[a'))
t.eq('error.Syntax 0: This class is not closed. Add `]`, or write `\\[` to match a bracket.', err_of('[]'))
t.eq('error.Syntax 0: The repetition `*` has nothing to repeat. Write `\\*` to match the character.', err_of('*a'))
t.eq(true, err_of('a|+').starts_with('error.Syntax 2: The repetition `+`'))
t.eq(true, err_of('(?i)*').starts_with('error.Syntax 4: The repetition `*`'))
t.eq('error.Syntax 1: The repetition `{2,1}` has a minimum over its maximum.', err_of('a{2,1}'))
t.eq(true, err_of('a{').starts_with('error.Syntax 2: Expected a number in the repetition'))
t.eq(true, err_of('a{,2}').starts_with('error.Syntax 2: Expected a number in the repetition'))
t.eq(true, err_of('a{1').starts_with('error.Syntax 3: Expected `}`'))
t.eq(true, err_of('{1}').starts_with('error.Syntax 0: The repetition `{`'))
t.eq('error.Syntax 2: The range `z` to `a` is backwards. Write `\\-` for a dash that is not a range.', err_of('[z-a]'))
t.eq(true, err_of('[a-\\d]').starts_with('error.Syntax 3: A range ends with one character'))
t.eq(true, err_of('[\\b]').starts_with('error.Syntax 1: The assertion `\\b` can not be in a class.'))
t.eq(true, err_of('[[:foo:]]').starts_with('error.Syntax 1: Unknown class `[:foo:]`.'))
t.eq('error.Syntax 12: There are two groups named `n`.', err_of('(?P<n>a)(?P<n>b)'))
t.eq(true, err_of('(?P<1a>x)').starts_with('error.Syntax 4: A group name starts with a letter'))
t.eq(true, err_of('(?P<>x)').starts_with('error.Syntax 4: The group name is empty.'))
t.eq(true, err_of('(?P<n').starts_with('error.Syntax 4: The group name is not closed.'))
t.eq(true, err_of('(?z)').starts_with('error.Syntax 2: Unknown flag `z`.'))
t.eq(true, err_of('(?)').starts_with('error.Syntax 0: Expected a flag'))
t.eq(true, err_of('(?i-)').starts_with('error.Syntax 4: Expected a flag after `-`'))
t.eq(true, err_of('(?ii)').starts_with('error.Syntax 3: The flag `i` is given twice.'))
t.eq(true, err_of('(?i').starts_with('error.Syntax 0: This group is not closed.'))
t.eq('error.Syntax 1: The pattern ends with a `\\`. Write `\\\\` to match a backslash.', err_of('a\\'))
t.eq(true, err_of('\\q').starts_with('error.Syntax 0: Unknown escape `\\q`.'))
t.eq(true, err_of('\\é').starts_with('error.Syntax 0: A `\\` before `é` has no meaning.'))
t.eq(true, err_of('\\xZ1').starts_with('error.Syntax 2: Expected 2 hex digits'))
t.eq(true, err_of('\\x{110000}').starts_with('error.Syntax 0: The escape is not a Unicode code point'))
t.eq(true, err_of('\\u{D800}').starts_with('error.Syntax 0: The escape is not a Unicode code point'))
t.eq(true, err_of('\\x{}').starts_with('error.Syntax 0: The escape needs one to eight hex digits'))
t.eq(true, err_of('\\b{foo}').starts_with('error.Syntax 2: Unknown word boundary `\\b{foo}`.'))
t.eq(true, err_of('\\p{L').starts_with('error.Syntax 0: The class `\\p{` is not closed.'))
t.eq('error.Syntax 0: The pattern is not valid UTF-8.', err_of(str([]byte{'a', 0xff})))
t.eq('ok', err_of('a]}'))

-- Limits.
t.eq(false, fails('(' ** 249 + 'a' + ')' ** 249))
t.eq(true, err_of('(' ** 251 + 'a' + ')' ** 251).starts_with('error.Syntax 250: The pattern nests deeper than 250 levels.'))
t.eq(true, fails('[a' ** 300 + ']' ** 300))
t.eq(true, fails('a' + '*' ** 300))
t.eq(false, fails(`\w{30000}`))
t.eq('error.TooBig 3: The repetition count is over the limit of 32768.', err_of(`\w{40000}`))
t.eq(true, err_of(`(?:a{1000}){1000}`).starts_with('error.TooBig 0: The pattern is too big: its program has more than 32768 instructions.'))
t.eq(true, err_of(`(?:(?:){30000}){30000}`).starts_with('error.TooBig 0: The pattern is too big: it repeats too many times.'))

-- Time is linear in the input: these patterns take exponential time with backtracking.
many := 'a' ** 20000
t.eq(false, regex.compile(`(a*)*b`)!.is_match(many))
t.eq(false, regex.compile(`(a+)+$`)!.is_match(many + 'b' + many + '!'))
t.eq(false, regex.compile(`(x+x+)+y`)!.is_match('x' ** 20000))
t.eq(true, regex.compile(`(?:a?){100}a{100}`)!.is_match('a' ** 100))

-- A compiled pattern is a value: it can be copied and used again.
re2 := re
t.eq(true, re2.is_match('a=1'))
t.eq(true, regex.unicode_version().len() >= 5)

--cytest: pass
