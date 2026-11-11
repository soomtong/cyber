use test

type Bag:
    n int
    names ^ArrayStore[str]

-- Method generator.
generator fn (^Bag) items() -> int:
    for 0..self.n |i|:
        yield i

b := ^Bag{n=3, names=^{}}
total := 0
for b.items() |v|:
    total += v
test.eq(3, total)

-- Not started until the first `next`.
generator fn (^Bag) record(name str) -> int:
    self.names << name
    yield self.names.len()
    self.names << (name + '!')
    yield self.names.len()

gen := b.record('a')
test.eq(0, b.names.len())
test.eq(1, gen.next().?)
test.eq(2, gen.next().?)
test.eq(?int(none), gen.next())
test.eq('a!', b.names[1])

-- The generator keeps the receiver alive.
fn sum_kept() -> int:
    tmp := ^Bag{n=4, names=^{}}
    g := tmp.items()
    tmp = ^Bag{n=0, names=^{}}
    sum := 0
    for g |v|:
        sum += v
    return sum
test.eq(6, sum_kept())

-- Dropped before it ends.
gen3 := b.items()
test.eq(0, gen3.next().?)

-- Method generator of managed values.
generator fn (^Bag) each_name() -> str:
    for 0..self.names.len() |i|:
        yield self.names[i]
joined := ''
for b.each_name() |s|:
    joined += s
test.eq('aa!', joined)

-- Template generator, expanded explicitly.
generator fn rep[T Any](x T, n int) -> T:
    for 0..n |i|:
        yield x
total = 0
for rep[int](5, 3) |v|:
    total += v
test.eq(15, total)
joined = ''
for rep[str]('ab', 2) |s|:
    joined += s
test.eq('abab', joined)

-- Generic generator, type inferred from the argument.
generator fn rep2(x %T, n int) -> T:
    for 0..n |i|:
        yield x
total = 0
for rep2(7, 2) |v|:
    total += v
test.eq(14, total)
joined = ''
for rep2('c', 3) |s|:
    joined += s
test.eq('ccc', joined)

-- Method generator of a template type.
type Box[T Any]:
    val T

generator fn (^Box[]) twice() -> T:
    yield self.val
    yield self.val

bx := ^Box[int]{val=21}
total = 0
for bx.twice() |v|:
    total += v
test.eq(42, total)

--cytest: pass