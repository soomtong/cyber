use test

-- Operands are evaluated left to right, also when a later operand needs a temporary (F-98).
log := ^ArrayStore[str]{}
type A:
    n int
fn mk(log ^ArrayStore[str], n int) -> A:
    log << 'mk%{n}'
    return A{n=n}
fn (&A) get(log ^ArrayStore[str]) -> int:
    log << 'get%{self.n}'
    return self.n
fn word(log ^ArrayStore[str], s str) -> str:
    log << 'word-%{s}'
    return s + '!'
fn fail(log ^ArrayStore[str]) -> !str:
    log << 'fail'
    return error.Boom
fn pick(a %T, b T) -> T:
    return b
-- An owned value that waits for a later operand is destructed when that operand returns early.
fn early(log ^ArrayStore[str]) -> !str:
    return word(log, 'a') + fail(log)!
r := early(log)
test.eq(r.unwrap_error(), error.Boom)
test.eq(log.len(), 2)
test.eq(log[0], 'word-a')
test.eq(log[1], 'fail')
-- Generic call.
log = ^ArrayStore[str]{}
_ = pick(mk(log, 1).get(log), mk(log, 2).get(log))
test.eq(log[0] + log[1] + log[2] + log[3], 'mk1get1mk2get2')
-- Overloaded callee: a candidate that does not match is retried.
fn over(a int, b str) -> int:
    return a
fn over(a int, b int) -> int:
    return a + b
log = ^ArrayStore[str]{}
x := mk(log, 1).get(log) + over(mk(log, 2).get(log), mk(log, 3).get(log))
test.eq(x, 6)
out := ''
for 0..log.len() |i|:
    out += log[i]
test.eq(out, 'mk1get1mk2get2mk3get3')

fn say(log ^ArrayStore[str], n int) -> int:
    log << 'say%{n}'
    return n
fn joined(log ^ArrayStore[str]) -> str:
    res := ''
    for 0..log.len() |i|:
        res += log[i]
    return res
fn add(a int, b int) -> int:
    return a + b
type P:
    a int
    b int

-- Binary operator with a plain call on the left.
log = ^ArrayStore[str]{}
test.eq(say(log, 1) + mk(log, 2).get(log), 3)
test.eq(joined(log), 'say1mk2get2')
log = ^ArrayStore[str]{}
test.eq(say(log, 1) < mk(log, 2).get(log), true)
test.eq(joined(log), 'say1mk2get2')

-- Call arguments, nested.
log = ^ArrayStore[str]{}
test.eq(add(say(log, 1), add(say(log, 2), mk(log, 3).get(log))), 6)
test.eq(joined(log), 'say1say2mk3get3')

-- Array, struct and string template.
log = ^ArrayStore[str]{}
arr := []int{say(log, 1), mk(log, 2).get(log)}
test.eq(arr[0] + arr[1], 3)
test.eq(joined(log), 'say1mk2get2')
log = ^ArrayStore[str]{}
p := P{a=say(log, 1), b=mk(log, 2).get(log)}
test.eq(p.a + p.b, 3)
test.eq(joined(log), 'say1mk2get2')
log = ^ArrayStore[str]{}
test.eq('%{say(log, 1)}-%{mk(log, 2).get(log)}', '1-2')
test.eq(joined(log), 'say1mk2get2')

-- Managed values on the left.
log = ^ArrayStore[str]{}
test.eq(word(log, 'a') + word(log, 'b') + str(mk(log, 3).get(log)), 'a!b!3')
test.eq(joined(log), 'word-aword-bmk3get3')

-- A later operand that adds statements (`!`) runs after the operands before it.
fn sayr(log ^ArrayStore[str], n int) -> !int:
    log << 'r%{n}'
    return n
fn says(log ^ArrayStore[str], n int) -> str:
    log << 's%{n}'
    return 'abcdef'
fn sayp(log ^ArrayStore[str], p Ptr[int]) -> Ptr[int]:
    log << 'p'
    return p
type IntFn = fn(int) -> int
fn inc(x int) -> int:
    return x + 1
fn getf(log ^ArrayStore[str]) -> IntFn:
    log << 'f'
    return inc

-- Map literal: the key before the value.
log = ^ArrayStore[str]{}
m := Map[int,int]{(say(log, 1))=sayr(log, 2)!, (say(log, 3))=say(log, 4)}
test.eq(m[1] + m[3], 6)
test.eq(joined(log), 'say1r2say3say4')
-- `..=` slice: the receiver and the start before the end.
log = ^ArrayStore[str]{}
test.eq(says(log, 1)[say(log, 0)..=sayr(log, 2)!], 'abc')
test.eq(joined(log), 's1say0r2')
log = ^ArrayStore[str]{}
test.eq(says(log, 1)[say(log, 0)..sayr(log, 2)!], 'ab')
test.eq(joined(log), 's1say0r2')
-- Range: the start before the end.
log = ^ArrayStore[str]{}
rg := say(log, 1) .. sayr(log, 3)!
test.eq(rg.end, 3)
test.eq(joined(log), 'say1r3')
log = ^ArrayStore[str]{}
rg = say(log, 1) ..= sayr(log, 3)!
test.eq(rg.end, 4)
test.eq(joined(log), 'say1r3')
-- Pointer index: the pointer before the index.
pv := 123
pv_ref := ^pv
pv_ptr := as[Ptr[int]] pv_ref
log = ^ArrayStore[str]{}
test.eq(sayp(log, pv_ptr)[sayr(log, 0)!], 123)
test.eq(joined(log), 'pr0')
-- Function pointer callee before the arguments.
log = ^ArrayStore[str]{}
test.eq(getf(log)(sayr(log, 2)!), 3)
test.eq(joined(log), 'fr2')

-- Compound assignment evaluates the receiver and the index of its left side once, before the right side.
fn key(log ^ArrayStore[str], s str) -> str:
    log << 'key-%{s}'
    return s
fn geta(log ^ArrayStore[str], a ^[]int) -> ^[]int:
    log << 'g'
    return a
fn getr(log ^ArrayStore[str], scope p &P) -> scope &P:
    log << 'g'
    return p
fn getm(log ^ArrayStore[str], m ^Map[str, int]) -> ^Map[str, int]:
    log << 'm'
    return m
fn ptr(log ^ArrayStore[str], p ^int) -> ^int:
    log << 'p'
    return p
type Box:
    xs []int
fn mkbox(log ^ArrayStore[str]) -> Box:
    log << 'box'
    return Box{xs=[]int{1, 2}}

log = ^ArrayStore[str]{}
ia := []int{10, 20, 30}
ia[say(log, 1)] += say(log, 2)
test.eq(ia[1], 22)
test.eq(joined(log), 'say1say2')
log = ^ArrayStore[str]{}
ha := ^[]int{1, 2, 3}
geta(log, ha)[say(log, 1)] += 1
test.eq(ha[1], 3)
test.eq(joined(log), 'gsay1')
log = ^ArrayStore[str]{}
pa := P{a=1, b=2}
getr(log, &pa).a += 5
test.eq(pa.a, 6)
test.eq(joined(log), 'g')
-- Map key, and a map from a call (`@index` and `@set_index`).
log = ^ArrayStore[str]{}
ms := Map[str, int]{}
ms['a'] = 1
ms[key(log, 'a')] += 10
test.eq(ms['a'], 11)
test.eq(joined(log), 'key-a')
log = ^ArrayStore[str]{}
hm := ^Map[str, int]{}
hm['a'] = 2
getm(log, hm)[key(log, 'a')] *= 3
test.eq(hm['a'], 6)
test.eq(joined(log), 'mkey-a')
-- Nested index, a field of an element, a dereference.
log = ^ArrayStore[str]{}
grid := [][]int{[]int{1, 2}, []int{3, 4}}
grid[say(log, 1)][say(log, 0)] += 100
test.eq(grid[1][0], 103)
test.eq(joined(log), 'say1say0')
log = ^ArrayStore[str]{}
ps := []P{P{a=1, b=2}, P{a=3, b=4}}
ps[say(log, 1)].b -= 1
test.eq(ps[1].b, 3)
test.eq(joined(log), 'say1')
log = ^ArrayStore[str]{}
hn := ^int(5)
ptr(log, hn).* += say(log, 2)
test.eq(hn.*, 7)
test.eq(joined(log), 'psay2')
-- Other operators and a managed element.
log = ^ArrayStore[str]{}
bits := []int{1, 2}
bits[say(log, 0)] ||= 6
bits[say(log, 1)] <<= say(log, 3)
test.eq(bits[0], 7)
test.eq(bits[1], 16)
test.eq(joined(log), 'say0say1say3')
log = ^ArrayStore[str]{}
ss := []str{'a', 'b'}
ss[say(log, 1)] += 'c'
test.eq(ss[1], 'bc')
test.eq(joined(log), 'say1')
-- An owned receiver is held for the statement and destructed after it.
log = ^ArrayStore[str]{}
mkbox(log).xs[say(log, 0)] += 1
test.eq(joined(log), 'boxsay0')

--cytest: pass