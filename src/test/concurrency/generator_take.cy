use test

generator fn naturals() -> int:
    i := 0
    while:
        yield i
        i += 1

generator fn three() -> int:
    yield 1
    yield 2
    yield 3

fn collect(t GeneratorTake[%F]) -> []int:
    var out []int = {}
    for t |v|:
        out += v
    return out

-- The first values of an endless generator.
test.eq_span([]int{0, 1, 2, 3}.span(), collect(naturals().take(4)).span())
test.eq(0, collect(naturals().take(0)).len())

-- Fewer when the generator ends first, and `none` after that.
t := three().take(10)
test.eq_span([]int{1, 2, 3}.span(), collect(t).span())
test.eq(true, t.next() == none)
test.eq(true, t.next() == none)

-- A generator in a variable goes on after the values that were taken.
g := naturals()
test.eq_span([]int{0, 1}.span(), collect(g.take(2)).span())
test.eq(2, g.next().?)
test.eq_span([]int{3, 4}.span(), collect(g.take(2)).span())

-- Managed values, and what is left of the generator is ended.
generator fn words() -> str:
    yield 'a' + 'b'
    yield 'c' + 'd'
var got []str = {}
for words().take(1) |w|:
    got += w
test.eq(1, got.len())
test.eq('ab', got[0])

--cytest: pass
