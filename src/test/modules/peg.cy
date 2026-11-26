use peg
use t 'test'

-- Where a grammar matches at the start of `s`: the end of the match, or -1.
fn ends(src str, s str) -> int:
    p := peg.compile(src) !else:
        return -2
    if p.match(s) |c|:
        return c.end
    return -1

-- The captures of a match as text: `name=text(kids) ...`.
fn show(c &peg.Capture) -> str:
    out := ''
    for c.kids |k|:
        if out.len() > 0:
            out += ' '
        if k.name.len() > 0:
            out += k.name + '='
        out += k.text
        if k.kids.len() > 0:
            out += '(' + show(&k) + ')'
    return out

fn caps(src str, s str) -> str:
    p := peg.compile(src) !else:
        return 'error'
    if p.match(s) |c|:
        return show(&c)
    return 'none'

-- The message and position of a grammar that does not compile.
fn err_of(src str) -> str:
    var diag peg.Diag = {}
    try:
        _ = peg.compile(src, &&diag)!
    else |err|:
        return '%{err} %{diag.pos}: %{diag.msg}'
    return 'ok'

-- The message of a `parse` that fails.
fn parse_err(src str, s str) -> str:
    p := peg.compile(src) !else:
        return 'grammar'
    var diag peg.Diag = {}
    try:
        _ = p.parse(s, &&diag)!
    else |err|:
        return '%{err} %{diag.pos}: %{diag.msg}'
    return 'ok'

-- Literals, classes and the dot.
t.eq(3, ends(`'abc'`, 'abcd'))
t.eq(-1, ends(`'abc'`, 'abd'))
t.eq(3, ends(`"abc"`, 'abc'))
t.eq(0, ends(`''`, 'abc'))
t.eq(2, ends(`'a' 'b'`, 'abc'))
t.eq(1, ends(`[a-c]`, 'b'))
t.eq(-1, ends(`[a-c]`, 'd'))
t.eq(1, ends(`[^a-c]`, 'd'))
t.eq(-1, ends(`[^a-c]`, 'a'))
t.eq(1, ends(`[abc-]`, '-'))
t.eq(1, ends(`[a\-c]`, '-'))
t.eq(-1, ends(`[a\-c]`, 'b'))
t.eq(1, ends(`[\]]`, ']'))
t.eq(1, ends(`[\^a]`, '^'))
t.eq(1, ends(`.`, 'x'))
t.eq(-1, ends(`.`, ''))
t.eq(3, ends("'a\\nb'", 'a\nb'))
t.eq(3, ends("'\\t\\r\\\\'", '\t\r\\'))
t.eq(2, ends("'\\'\\\"'", '\'"'))
t.eq(1, ends("'\\x41'", 'A'))
t.eq(3, ends("'\\u{AC00}'", '가'))
t.eq(1, ends("[\\x41-\\x43]", 'B'))

-- The `%` classes are ASCII.
t.eq(3, ends(`%d+`, '123a'))
t.eq(-1, ends(`%d`, 'a'))
t.eq(2, ends(`%a+`, 'aZ1'))
t.eq(3, ends(`%w+`, 'aZ1_'))
t.eq(2, ends(`%s+`, ' \tx'))
t.eq(2, ends(`%x+`, 'fFg'))
t.eq(1, ends(`%l+`, 'aA'))
t.eq(1, ends(`%u+`, 'Aa'))
t.eq(2, ends(`%p+`, '!?a'))
t.eq(1, ends(`%c`, '\t'))
t.eq(1, ends(`%g`, '!'))
t.eq(-1, ends(`%g`, ' '))
t.eq(1, ends(`%D`, 'a'))
t.eq(-1, ends(`%D`, '1'))
t.eq(5, ends(`%S+`, 'ab가 c'))
t.eq(1, ends(`%nl`, '\n'))
t.eq(4, ends(`[_%w]+`, 'a_1Z-'))
t.eq(2, ends(`[%d%s]+`, '1 a'))
t.eq(1, ends(`[%D]`, 'a'))
t.eq(-1, ends(`[%D]`, '5'))
t.eq(-1, ends(`%a`, 'é'))
t.eq(-1, ends(`%w`, '가'))

-- Matching is by code point.
t.eq(3, ends(`.`, '가나'))
t.eq(4, ends(`.`, '😀'))
t.eq(6, ends(`[가-힣]+`, '가나a'))
t.eq(-1, ends(`[가-힣]`, 'a'))
t.eq(3, ends(`[^a]`, '가'))
t.eq(6, ends(`'가' .`, '가나다'))
t.eq(2, ends(`[à-ÿ]`, 'é'))
-- A byte that is not UTF-8 is one unit: the dot and a negated class take it, a class does not.
bad := str([]byte{0xff, 'a'})
t.eq(1, ends(`.`, bad))
t.eq(2, ends(`. .`, bad))
t.eq(1, ends(`[^a]`, bad))
t.eq(-1, ends(`[\u{80}-\u{10FFFF}]`, bad))
t.eq(-1, ends(`!.`, bad))
t.eq(1, ends(`%S`, bad))
t.eq(1, ends(`%D`, bad))
t.eq(-1, ends(`%a`, bad))
t.eq(-1, ends(`[%S]`, bad))
t.eq(3, ends(`. . .`, str([]byte{0xea, 0xb0, 'a'})))

-- Choice is ordered, repetition takes all it can and gives nothing back.
t.eq(1, ends(`'a' / 'ab'`, 'ab'))
t.eq(2, ends(`'ab' / 'a'`, 'ab'))
t.eq(1, ends(`'x' / 'y' / 'a'`, 'a'))
t.eq(3, ends(`'a'*`, 'aaab'))
t.eq(0, ends(`'a'*`, 'b'))
t.eq(-1, ends(`'a'+`, 'b'))
t.eq(1, ends(`'a'?`, 'aa'))
t.eq(0, ends(`'a'?`, 'b'))
t.eq(-1, ends(`'a'* 'a'`, 'aaa'))
t.eq(-1, ends(`('a' / 'ab') 'c'`, 'abc'))
t.eq(3, ends(`('ab' / 'a') 'c'`, 'abc'))
t.eq(3, ends(`'a'^3`, 'aaaa'))
t.eq(-1, ends(`'a'^3`, 'aa'))
t.eq(4, ends(`'a'^+2`, 'aaaa'))
t.eq(-1, ends(`'a'^+2`, 'a'))
t.eq(2, ends(`'a'^-2`, 'aaaa'))
t.eq(1, ends(`'a'^-2`, 'ab'))
t.eq(0, ends(`'a'^-2`, 'b'))
t.eq(0, ends(`'a'^0`, 'a'))
t.eq(4, ends(`('a' 'b')^2`, 'ababab'))
t.eq(6, ends(`[ab]* 'c'?`, 'ababab'))
t.eq(4, ends(`('a' / 'b' 'c')*`, 'abcab'))

-- Predicates take no input.
t.eq(1, ends(`&'ab' 'a'`, 'ab'))
t.eq(-1, ends(`&'ab' 'a'`, 'ac'))
t.eq(1, ends(`!'ab' 'a'`, 'ac'))
t.eq(-1, ends(`!'ab' 'a'`, 'ab'))
t.eq(3, ends(`(!'x' .)*`, 'abcx'))
t.eq(0, ends(`!.`, ''))
t.eq(-1, ends(`!.`, 'a'))
t.eq(1, ends(`!!'a' .`, 'a'))
t.eq(1, ends(`& 'a' 'a'`, 'a'))

-- Rules.
t.eq(5, ends("s <- '(' s ')' / 'x'", '((x))'))
t.eq(-1, ends("s <- '(' s ')' / 'x'", '((x)'))
t.eq(7, ends("""
    -- A comment.
    expr   <- term ([+-] term)*
    term   <- factor ([*/] factor)*   # Another comment.
    factor <- %d+ / '(' expr ')'
""", '1+(2*3)'))
t.eq(4, ends("a <- 'x' b\nb <- 'y' a / 'z'", 'xyxz'))
t.eq(3, ends("a<-'x'b b<-'yz'", 'xyz'))

-- A call at the end of the last choice of a rule does not grow the stack.
long := str([]byte(300000, 'a'))
t.eq(300000, ends("a <- !. / 'a' a", long))
t.eq(300000, ends("'a'*", long))
t.eq(300000, ends("('a' / 'b')*", long))

-- Captures.
t.eq('a', caps(`{'a'}`, 'ab'))
t.eq('', caps(`'a'`, 'ab'))
t.eq('a b', caps(`{'a'} {'b'}`, 'ab'))
t.eq('ab(a b)', caps(`{ {'a'} {'b'} }`, 'ab'))
t.eq('k=a v=1', caps(`{:k: %a+ :} '=' {:v: %d+ :}`, 'a=1'))
t.eq('p=a=1(k=a v=1)', caps(`{:p: {:k: %a+ :} '=' {:v: %d+ :} :}`, 'a=1'))
t.eq('a a a', caps(`{'a'}*`, 'aaa'))
t.eq('b', caps(`{'a'} 'x' / {'b'}`, 'b'))
t.eq('b', caps(`{'a'} 'x' / 'a' {'b'}`, 'ab'))
t.eq('', caps(`&{'a'} 'a'`, 'a'))
t.eq('', caps(`!{'b'} 'a'`, 'a'))
t.eq('a', caps(`({'a'} 'x')? {'a'}`, 'ab')[0..1])
t.eq('1 2 3', caps("list <- item (',' item)*\nitem <- {%d+}", '1,2,3'))
t.eq('', caps(`{}`, 'a'))
pos := peg.compile(`'ab' {} 'c'`)!.match('abc').?
t.eq(1, pos.len())
t.eq(2, pos.kids[0].start)
t.eq(2, pos.kids[0].end)

-- String and substitution captures.
t.eq('x', caps(`'a' -> 'x'`, 'a'))
t.eq('<a>', caps(`'a' -> '<%0>'`, 'a'))
t.eq('b-a(a b)', caps(`({'a'} {'b'}) -> '%2-%1'`, 'ab'))
t.eq('100%', caps(`%d+ -> '%0%%'`, '100'))
t.eq('[](a)', caps(`{'a'} -> "[%2]"`, 'a'))
t.eq('bbnbnb', caps(`{~ ('a' -> 'b' / .)* ~}`, 'banana')[0..6])
t.eq('a,b;c', peg.compile(`{~ ((',' -> ';') / (';' -> ',') / .)* ~}`)!.match('a;b,c').?[0])
t.eq('ab', caps(`{~ 'a' {'b'} ~}`, 'ab')[0..2])
t.eq('x=1&y=2', peg.compile("""
    q    <- {~ pair (sep pair)* ~}
    pair <- %a+ ('=' -> '=') %d+
    sep  <- ' '+ -> '&'
""")!.match('x=1   y=2').?[0])

-- Back references.
t.eq(5, ends(`{:q: ['"] :} (!=q .)* =q`, '"a\'b"'))
t.eq(-1, ends(`{:q: ['"] :} (!=q .)* =q`, '"ab\''))
-- A back reference sees the outer capture of a name, not one inside it, as in LPeg.
t.eq(4, ends(`{:n: 'a' {:n: 'b' :} :} =n`, 'abab'))
t.eq(-1, ends(`{:n: 'a' {:n: 'b' :} :} =n`, 'abb'))
-- A capture that is still open is passed: the captures before it and inside it are seen.
t.eq(3, ends(`{:n: 'a' :} {:n: 'b' =n :}`, 'aba'))
t.eq(3, ends(`{:n: 'x' :} {:m: {:n: 'a' :} =n :}`, 'xaa'))
t.eq(5, ends(`{:w: %a+ :} ' ' =w`, 'ab abc'))
t.eq(-1, ends(`{:w: %a+ :} ' ' =w`, 'ab cd'))
-- The capture that was closed last counts, and one that was backtracked over does not.
t.eq(4, ends(`{:w: 'a' :} {:w: 'b' :} =w =w`, 'abbb'))
t.eq(-1, ends(`=w`, 'a'))
t.eq(2, ends(`({:w: 'a' :} 'x' / 'a') (=w / 'b')`, 'ab'))
-- Lua long brackets.
long_str := peg.compile("""
    s     <- open {:body: (!close .)* :} close
    open  <- '[' {:eq: '='* :} '['
    close <- ']' =eq ']'
""")!
t.eq(']]', long_str.match('[==[]]]==]').?['body'])
t.eq(true, long_str.match('[==[x]=]') == none)

-- The tree.
p := peg.compile("""
    list  <- '(' item (',' item)* ')'
    item  <- {:list: list :} / {:num: %d+ :}
""")!
c := p.parse('(1,(22,3),4)')!
t.eq('', c.name)
t.eq(0, c.start)
t.eq(12, c.end)
t.eq('(1,(22,3),4)', c.text)
t.eq(3, c.len())
t.eq('1', c[0])
t.eq('(22,3)', c[1])
t.eq('4', c[2])
t.eq('num', c.kids[0].name)
t.eq('list', c.kids[1].name)
t.eq(3, c.kids[1].start)
t.eq(9, c.kids[1].end)
t.eq('22', c.kids[1][0])
t.eq('1', c['num'])
t.eq('(22,3)', c['list'])
t.eq('', c['nope'])
t.eq('22', c.get('list').?['num'])
t.eq(true, c.get('nope') == none)
nums := c.all('num')
t.eq(4, nums.len())
t.eq('22', nums[1].text)
t.eq(4, nums[1].start)
t.eq('4', nums[3].text)
t.eq(0, c.all('nope').len())
t.eq(1, c.all('list').len())

-- `match` is anchored and takes a prefix, `parse` takes everything.
kv := peg.compile(`{:key: %w+ :} '=' {:val: %d+ :}`)!
t.eq(true, kv.match('a=1 b=2') != none)
t.eq(3, kv.match('a=1 b=2').?.end)
t.eq(true, kv.match(' a=1') == none)
t.eq('2', kv.match('a=1 b=2', 4).?['val'])
t.eq(4, kv.match('a=1 b=2', 4).?.start)
t.eq(true, kv.match('a=1', 9) == none)
t.eq(true, kv.match('a=1', -1) == none)
t.eq('1', kv.parse('a=1')!['val'])
t.eq(kv.source(), `{:key: %w+ :} '=' {:val: %d+ :}`)

-- Searching.
t.eq('retries', kv.find('set retries=3 now').?['key'])
t.eq(4, kv.find('set retries=3 now').?.start)
t.eq(13, kv.find('set retries=3 now').?.end)
t.eq(true, kv.find('nothing') == none)
t.eq('b', kv.find('a=1 b=2', 1).?['key'])
t.eq(true, kv.find('a=1', 4) == none)
all := kv.find_all('a=1, bb=22; c=3')
t.eq(3, all.len())
t.eq('bb', all[1]['key'])
t.eq('22', all[1]['val'])
t.eq(5, all[1].start)
t.eq(0, kv.find_all('').len())
-- Empty matches: one at each place, and none right after a match.
digits := peg.compile(`%d*`)!
t.eq(3, digits.find_all('a12b').len())
t.eq('12', digits.find_all('a12b')[1].text)
t.eq(2, digits.find_all('가').len())
t.eq(1, digits.find_all('').len())
-- A byte that is not part of valid UTF-8 is one unit, so an empty match does not skip what follows it.
opt_a := peg.compile(`'a'?`)!
t.eq(3, opt_a.find_all('\xf8aba').len())
t.eq(1, opt_a.find_all('\xf8aba')[1].start)
t.eq(3, opt_a.find_all('\xf8aba')[2].start)
t.eq(4, peg.compile(`''`)!.find_all('\xc0ab').len())

-- Replacing and splitting.
t.eq('1:a 2:b', kv.replace_all('a=1 b=2', '$val:$key'))
t.eq('1:a b=2', kv.replace('a=1 b=2', '$val:$key'))
t.eq('[a=1] [b=2]', kv.replace_all('a=1 b=2', '[$0]'))
t.eq('a1 b2', kv.replace_all('a=1 b=2', '$1$2'))
t.eq('a_1 $ ${x}', kv.replace_all('a=1', '${key}_${2} $$ $${x}'))
t.eq('- -', kv.replace_all('a=1 b=2', '-'))
t.eq('<> <>', kv.replace_all('a=1 b=2', '<$nope$9>'))
t.eq('none', kv.replace_all('none', 'x'))
t.eq('none', kv.replace('none', 'x'))
t.eq('-a-b-', peg.compile(`'x'*`)!.replace_all('axxb', '-'))
-- A function gives the replacement for the capture of each match.
t.eq('A=1 B=2', kv.replace_all('a=1 b=2', |c| c['key'].upper() + '=' + c['val']))
t.eq('[a] b=2', kv.replace('a=1 b=2', |c| '[' + c['key'] + ']'))
t.eq('$1 $1', kv.replace_all('a=1 b=2', |c| '$1'))
t.eq('none', kv.replace_all('none', |c| 'x'))
t.eq('none', kv.replace('none', |c| 'x'))
t.eq('-a-b-', peg.compile(`'x'*`)!.replace_all('axxb', |c| '-'))
fn kid_count(c &peg.Capture) -> str:
    return str(c.len())
t.eq('2 2', kv.replace_all('a=1 b=2', kid_count))
sep := peg.compile(`%s* ',' %s*`)!
parts := sep.split('a , b,c ,  d')
t.eq(4, parts.len())
t.eq('a', parts[0])
t.eq('b', parts[1])
t.eq('d', parts[3])
t.eq(1, sep.split('abc').len())
t.eq(2, sep.split(',').len())
t.eq('', sep.split(',')[1])
m := kv.match('a=1').?
t.eq('1 a a=1', m.expand('$val $key $0'))

-- Grammars that do not compile.
t.eq("error.Syntax 0: The rule `a` is left recursive (a -> a): it calls itself before it takes any input, which never ends. Write the repetition as a loop: `a <- b (op b)*`.", err_of("a <- a 'x' / 'y'"))
t.eq(true, err_of("a <- b 'x'  b <- c?  c <- a").index('(a -> b -> c -> a)') != none)
t.eq(true, err_of("a <- 'x'? a").index('left recursive') != none)
t.eq(true, err_of("a <- &'x' a").index('left recursive') != none)
t.eq(true, err_of("a <- {} a").index('left recursive') != none)
t.eq('ok', err_of("a <- 'x' a / ''"))
t.eq('ok', err_of("a <- a^0 'x'"))
t.eq('error.Syntax 0: This repetition never ends: what it repeats can match without taking any input.', err_of("('a'?)*"))
t.eq(true, err_of("a <- b+  b <- 'x'*").index('never ends') != none)
t.eq(true, err_of("(!'a')*").index('never ends') != none)
t.eq('ok', err_of("('a'?)^3"))
t.eq("error.Syntax 4: A choice is written `a / b`, not `a | b`.", err_of("'a' | 'b'"))
t.eq("error.Syntax 0: There is no rule `x`. Text goes in quotes: `'x'`. A rule is defined as `x <- ...`.", err_of('x'))
t.eq('error.Syntax 9: The rule `b` is not defined.', err_of("a <- 'x' b"))
t.eq('error.Syntax 9: The rule `a` is defined twice.', err_of("a <- 'x' a <- 'y'"))
t.eq('error.Syntax 0: This class is not closed.', err_of('[a-'))
t.eq('error.Syntax 0: This class is empty. Write `\\]` for a `]` in a class.', err_of('[]'))
t.eq('error.Syntax 2: The range `z-a` ends before it starts.', err_of('[z-a]'))
t.eq('error.Syntax 0: This string is not closed.', err_of("'abc"))
t.eq(true, err_of("'a\\q'").index('Unknown escape `\\q`') != none)
t.eq(true, err_of("'\\xZZ'").index('two hex digits') != none)
t.eq(true, err_of("'\\xFF'").index('`\\u{FF}`') != none)
t.eq(true, err_of("'\\u{110000}'").index('not a Unicode code point') != none)
t.eq(true, err_of("'\\u{D800}'").index('not a Unicode code point') != none)
t.eq(true, err_of('{| %d |}').index('table capture') != none)
t.eq(true, err_of("{: 'a' :}").index('A named capture is `{:name: p :}`') != none)
t.eq(true, err_of("'a'{3}").index('`p^3`') != none)
t.eq(true, err_of('\\d+').index('not `\\d`') != none)
t.eq(true, err_of("'a' -> f").index('Only a string can follow `->`') != none)
t.eq(true, err_of("'a' -> 3").index('Only a string can follow `->`') != none)
t.eq(true, err_of("'a' => f").index('calls a function') != none)
t.eq(true, err_of("'a' -> '%x'").index('followed by a digit') != none)
t.eq(true, err_of('%q').index('Unknown class') != none)
t.eq(true, err_of('[%w_]').index('Put the other characters first: `[_%w]`') != none)
t.eq(true, err_of('<a>').index('without `<` and `>`') != none)
t.eq(true, err_of("'a' $").index('`!.`') != none)
t.eq(true, err_of("* 'a'").index('nothing to repeat') != none)
t.eq(true, err_of("('a'").index('Expected `)` to close the group') != none)
t.eq(true, err_of("{'a'").index('Expected `}` to close the capture') != none)
t.eq(true, err_of("{:n: 'a' }").index('Expected `:}`') != none)
t.eq(true, err_of("'a')").index('closes no group') != none)
t.eq(true, err_of("'a'}").index('closes no capture') != none)
t.eq(true, err_of('가').index('Text goes in quotes') != none)
t.eq(true, err_of('=').index('name of a capture') != none)
t.eq(true, err_of("!").index('Expected a pattern after `!`') != none)
t.eq(true, err_of("'a'^").index('Expected a number after `^`') != none)
t.eq('error.Syntax 0: The grammar is not valid UTF-8.', err_of(str([]byte{'\'', 0xff, '\''})))
-- The line and the column of an error.
var gd peg.Diag = {}
try:
    _ = peg.compile("a <- 'x'\nb <- 'y' | 'z'", &&gd)!
else:
    pass
t.eq(2, gd.line)
t.eq(10, gd.col)
t.eq(18, gd.pos)

-- Limits of a grammar.
t.eq('error.TooBig 4: The repetition count is over the limit of 65536.', err_of("'a'^70000"))
t.eq(true, err_of("('a'^300)^300").index('more than 65536 instructions') != none)
t.eq(true, err_of("((''^300)^300)^300").index('repeats too many times') != none)
deep := ''
for 0..300 |_i|:
    deep += '('
deep += "'a'"
for 0..300 |_i|:
    deep += ')'
t.eq(true, err_of(deep).index('nests deeper than 250 levels') != none)
stars := "'a'"
for 0..300 |_i|:
    stars += '?'
t.eq(true, err_of(stars).index('nests deeper than 250 levels') != none)

-- `parse` tells the farthest failure and what was expected there.
t.eq("error.NoMatch 3: Expected `'('` or `%d` at line 1, column 4, found `)`.", parse_err("list <- '(' item (',' item)* ')'\nitem <- list / %d+", '(1,)'))
t.eq("error.NoMatch 2: Expected `%d`, `','` or `')'` at line 1, column 3, found the end of the input.", parse_err("list <- '(' item (',' item)* ')'\nitem <- list / %d+", '(1'))
-- A repeated set tells the same as any other repetition where it stops.
t.eq("error.NoMatch 3: Expected the end of the input, `[a-z]` or `' '` at line 1, column 4, found `1`.", parse_err(`[a-z]+ ' '?`, 'abc1'))
t.eq("error.NoMatch 3: Expected the end of the input, `[a-z]` or `' '` at line 1, column 4, found `1`.", parse_err(`[a-z]* ' '?`, 'abc1'))
t.eq("error.NoMatch 2: Expected the end of the input, `'a'` or `' '` at line 1, column 3, found `1`.", parse_err(`('a')* ' '?`, 'aa1'))
t.eq("error.NoMatch 1: Expected the end of the input at line 1, column 2, found `b`.", parse_err("'a'", 'ab'))
t.eq("error.NoMatch 2: Expected the end of the input or `'a'` at line 1, column 3, found `b`.", parse_err("'a'*", 'aab'))
t.eq("error.NoMatch 0: Expected `'a'` at line 1, column 1, found the end of the input.", parse_err("'a'", ''))
t.eq("error.NoMatch 4: Expected `[0-9]`, `'x'` or `'yz'` at line 2, column 2, found a line feed.", parse_err("'ab\n' . ([0-9] / 'x' / 'yz')", 'ab\nc\n'))
t.eq("error.NoMatch 5: Expected any character at line 3, column 1, found the end of the input.", parse_err("'ab\n' . ([0-9] / 'x' / . .)", 'ab\nc\n'))
t.eq("error.NoMatch 1: Expected the end of the input at line 1, column 2, found `b`.", parse_err("'a' !.", 'ab'))
t.eq("error.NoMatch 1: Expected not 'b' at line 1, column 2, found `b`.", parse_err("'a' !'b' .", 'ab'))
t.eq("error.NoMatch 1: Expected `'b'` at line 1, column 2, found `c`.", parse_err("'a' &'b' .", 'ac'))
t.eq("error.NoMatch 2: Expected `=q` at line 1, column 3, found `'`.", parse_err(`{:q: ['"] :} 'x' =q`, '"x\''))
t.eq("error.NoMatch 3: Expected `'나'` at line 1, column 4, found `다`.", parse_err("'가' '나'", '가다'))
-- A failure inside a predicate is not what was expected.
t.eq("error.NoMatch 1: Expected `'c'` at line 1, column 2, found `b`.", parse_err("'a' !('b' 'x') 'c'", 'ab'))
var pd peg.Diag = {}
try:
    _ = peg.compile("list <- '(' item (',' %s* item)* ')'\nitem <- list / %d+")!.parse('(1,\n2,\nx)', &&pd)!
else:
    pass
t.eq(3, pd.line)
t.eq(1, pd.col)
t.eq(7, pd.pos)
t.eq(3, pd.expected.len())
t.eq('%s', pd.expected[0])
t.eq("'('", pd.expected[1])
t.eq('%d', pd.expected[2])
t.eq('ok', parse_err("'a'*", 'aaa'))

-- Limits of a match.
nest := peg.compile("s <- '(' s ')' / 'x'")!
open := str([]byte(150000, '('))
t.eq(true, parse_err("s <- '(' s ')' / 'x'", open).starts_with('error.TooDeep 0: The match has more than 100000 open rule calls and choices.'))
ok_depth := str([]byte(40000, '(')) + 'x' + str([]byte(40000, ')'))
t.eq(80001, nest.parse(ok_depth)!.end)
many := peg.compile(`{.}*`)!
t.eq(true, parse_err(`{.}*`, str([]byte(1000001, 'a'))).starts_with('error.TooBig 0: The match has more than 1000000 captures.'))
t.eq(400000, many.match(str([]byte(400000, 'a'))).?.len())

-- A literal with `i` after the quote ignores case, by the simple case folding of Unicode as `(?i)` of `regex`.
t.eq(6, ends(`'select'i`, 'SeLeCt'))
t.eq(6, ends(`"select"i`, 'SELECT'))
t.eq(-1, ends(`'select'i`, 'selec'))
t.eq(-1, ends(`'select'`, 'SELECT'))
-- The Kelvin sign and the long s fold to `k` and `s`, so the input can be longer in bytes than the literal.
t.eq(5, ends(`'ks'i`, str.init_rune(0x212a) + str.init_rune(0x17f)))
t.eq(2, ends(`'\u{212A}s'i`, 'kS'))
t.eq(4, ends(`'가a'i`, '가A'))
t.eq(-1, ends(`'a'i`, '\xc1'))
t.eq(1, ends(`''i 'a'`, 'a'))
t.eq(3, ends(`'ab'i 'c'`, 'ABc'))
t.eq(-1, ends(`'ab'i 'c'`, 'ABC'))
t.eq(4, ends(`{:kw: 'if'i :} !%w %s* 'x'`, 'IF x'))
t.eq(-1, ends(`'if'i !%w`, 'iffy'))
-- `i` that starts a longer name, or comes after a space, is a rule.
t.eq(2, ends("""
    s <- 'x' i
    i <- 'y'
""", 'xy'))
t.eq(2, ends("""
    s <- 'x'id
    id <- 'Y'
""", 'xY'))
var ci_diag peg.Diag = {}
t.eq(error.NoMatch, peg.compile(`'(' 'select'i`)!.parse('(selx', &&ci_diag).unwrap_error())
t.eq('Expected `\'select\'i` at line 1, column 2, found `s`.', ci_diag.msg)

-- A grammar that backtracks a lot still ends: `(a / a)* b` is linear, since a repetition gives nothing back.
t.eq(-1, ends(`('a' / 'a')* 'b'`, str([]byte(100000, 'a'))))

--cytest: pass
