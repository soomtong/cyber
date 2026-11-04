use test

-- Init generator without starting.
#[generator]
fn foo(list ^ArrayStore[int]) -> int:
    list << 123
list := ^ArrayStore[int]{}
gen := foo(list)
test.eq(list.len(), 0)

-- Start generator with yield at start.
#[generator]
fn foo2(list ^ArrayStore[int]) -> int:
    yield list.len()
    list << 123
gen = foo2(list)
test.eq(0, gen.next().?)
test.eq(list.len(), 0)

-- Generator with managed type.
#[generator]
fn foo3(list ^ArrayStore[int]) -> ^int:
    yield ^list.len()
    list << 123
list = ^{}
gen2 := foo3(list)
test.eq(0, gen2.next().?.*)

-- Start generator without yield.
#[generator]
fn foo4(list ^ArrayStore[int]) -> int:
    list << 123
list = ^{}
gen = foo4(list)
test.eq(?int(none), gen.next())

-- next() returns final value.
#[generator]
fn foo5(list ^ArrayStore[int]) -> int:
    list << 123
    return list[0]
list = ^{}
gen = foo5(list)
test.eq(123, gen.next().?)

-- -- Start generator with yield in nested function.
-- fn bar() -> int:
--     alist := []Object{}
--     yield 123
-- fn foo5(list []int) -> int:
--     yield* bar()
--     list.append(123)
-- list = {}
-- gen = foo5(list)
-- test.eq(123, gen.next().?)
-- test.eq(list.len(), 0)

-- Continue to resume generator.
#[generator]
fn foo6(list ^ArrayStore[int]) -> int:
    list << 123
    yield list.len()
    list << 234
    yield list.len()
list = ^{}
gen = foo6(list)
test.eq(1, gen.next().?)
test.eq(2, gen.next().?)

-- Generator status.
#[generator]
fn foo7() -> int:
    test.eq(static_gen.status(), .running)
type Fn7 = fn() -> int
global static_gen ^Generator[Fn7] = foo7()
test.eq(static_gen.status(), .paused)
_ = static_gen.next()
test.eq(static_gen.status(), .done)

-- Resuming after generator is done is a nop.
#[generator]
fn foo8() -> int:
    yield 123
gen3 := foo8()
_ = gen3.next()
_ = gen3.next()
test.eq(gen3.status(), .done)
-- gen3.next()
-- test.eq(gen3.status(), $done)

-- Recursive call in generator.
fn sum(n int) -> int:
    if n == 0:
        return 0
    return n + sum(n - 1)
#[generator]
fn genSum(n int) -> int:
    yield sum(n)
gen4 := genSum(20)
test.eq(210, gen4.next().?)

-- Locals and loop state survive yields, even when the consumer calls between resumes.
fn deep(n int) -> int:
    if n == 0:
        return 0
    return 1 + deep(n - 1)
#[generator]
fn counter() -> int:
    i := 10
    yield i
    i += 1
    yield i
    i += 1
    yield i
gen5 := counter()
test.eq(10, gen5.next().?)
_ = deep(30)
test.eq(11, gen5.next().?)
_ = deep(30)
test.eq(12, gen5.next().?)
test.eq(?int(none), gen5.next())

#[generator]
fn range_gen(n int) -> int:
    for 0..n |i|:
        yield i * 10
#[generator]
fn while_gen(n int) -> int:
    i := 0
    while i < n:
        yield i
        i += 1
sum5 := 0
gen6 := range_gen(4)
while gen6.next() |v|:
    sum5 += v
    _ = deep(20)
test.eq(60, sum5)
sum5 = 0
gen7 := while_gen(4)
while gen7.next() |v|:
    sum5 += v
    _ = deep(20)
test.eq(6, sum5)

-- Resumed from different call sites.
gen8 := counter()
a8 := gen8.next().?
b8 := gen8.next().?
c8 := gen8.next().?
test.eq(10, a8)
test.eq(11, b8)
test.eq(12, c8)

-- A managed local is yielded as a copy and keeps changing in the generator.
#[generator]
fn words(n int) -> str:
    s := 'w'
    for 0..n |i|:
        s = s + '-%{i}'
        yield s
    return 'end:' + s
gen9 := words(3)
test.eq('w-0', gen9.next().?)
test.eq('w-0-1', gen9.next().?)
test.eq('w-0-1-2', gen9.next().?)
test.eq('end:w-0-1-2', gen9.next().?)

-- Dropping a generator with a live managed local runs its destructor on the saved frame.
fn drop_words():
    g := words(5)
    _ = g.next()
    _ = g.next()
drop_words()

-- Resuming deep in the stack grows it before the generator frame is restored.
type CounterFn = fn() -> int
fn resume_deep(g ^Generator[CounterFn], n int) -> int:
    if n == 0:
        return g.next().?
    return resume_deep(g, n - 1)
gen10 := counter()
test.eq(10, resume_deep(gen10, 5000))
test.eq(11, resume_deep(gen10, 9000))

-- A wide generator frame resumed at every depth hits the stack end in `next()` itself.
#[generator]
fn wide() -> int:
    var a [200]int = undef
    a[0] = 7
    a[199] = 9
    yield a[0]
    yield a[199]
type WideFn = fn() -> int
fn wide_at(g ^Generator[WideFn], n int) -> int:
    if n == 0:
        return g.next().?
    return wide_at(g, n - 1)
wide_total := 0
for 0..300 |d|:
    gw := wide()
    wide_total += wide_at(gw, d)
    wide_total += wide_at(gw, d)
test.eq(4800, wide_total)

-- The stack grows while generator frames are running (nested generators, deep call inside).
#[generator]
fn inner_gen(n int) -> int:
    k := n
    yield deep(k)
    k = k * 2
    yield deep(k)
#[generator]
fn outer_gen() -> int:
    total := 0
    gi := inner_gen(8000)
    while gi.next() |v|:
        total += v
        yield total
gen11 := outer_gen()
test.eq(8000, gen11.next().?)
test.eq(24000, gen11.next().?)
test.eq(?int(none), gen11.next())

-- `for` iterates a generator until it is done.
#[generator]
fn count_gen(n int) -> int:
    for 0..n |i|:
        yield i * 10
for_total := 0
for count_gen(3) |v|:
    for_total += v
test.eq(30, for_total)

-- `for` with the index variable.
for_total = 0
for count_gen(3) |i, v|:
    for_total += i + v
test.eq(33, for_total)

-- `for` over a generator local retains it: the local is still valid after the loop and the generator is done.
gen12 := count_gen(2)
for_total = 0
for gen12 |v|:
    for_total += v
test.eq(10, for_total)
test.eq(gen12.status(), .done)

-- `for` resumes a generator from where it stopped.
gen13 := count_gen(4)
test.eq(0, gen13.next().?)
for_total = 0
for gen13 |v|:
    for_total += v
test.eq(60, for_total)

-- `for` over a generator of managed values.
#[generator]
fn str_gen() -> str:
    yield 'a'
    yield 'bc'
joined := ''
for str_gen() |s|:
    joined += s
test.eq('abc', joined)

-- -- coinit lambda
-- foof := (list []Object):
--     list.append(123)
-- list = {}
-- f = coinit(foof, list)
-- coresume f
-- test.eq(list[0], 123)

--cytest: pass