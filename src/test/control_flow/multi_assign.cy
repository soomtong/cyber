use test

-- Every right side is evaluated, from left to right, before the first value is stored.
a, b := 0, 1
for 0..10:
    a, b = b, a + b
test.eq(55, a)
test.eq(89, b)

-- A swap.
x, y := 'left', 'right'
x, y = y, x
test.eq('right', x)
test.eq('left', y)

-- The order of evaluation.
global calls []str = {}
fn note(s str, v int) -> int:
    calls += s
    return v
p, q := note('p', 1), note('q', 2)
test.eq_slice({'p', 'q'}, calls)
test.eq(3, p + q)

-- A literal takes the type of its target.
var i i32 = 0
var j i32 = 0
i, j = 3, -4
test.eq(i32(-1), i + j)

-- Fields and elements.
type Pt:
    x int
    y int
pt := Pt{x=1, y=2}
pt.x, pt.y = pt.y, pt.x
test.eq(2, pt.x)
test.eq(1, pt.y)
xs := []int{10, 20, 30}
xs[0], xs[2] = xs[2], xs[0]
test.eq_slice({30, 20, 10}, xs)

-- `NoCopy` values move: a swap of two `Array`s.
arr1 := Array[int]{1}
arr2 := Array[int]{2, 3}
arr1, arr2 = arr2, arr1
test.eq(2, arr1.len())
test.eq(1, arr2.len())

-- A declaration reads the names of an outer block before it declares its own.
outer_a, outer_b := 1, 2
begin:
    outer_a, outer_b := outer_b, outer_a
    test.eq(2, outer_a)
    test.eq(1, outer_b)
test.eq(1, outer_a)

-- In a function.
fn fib(n int) -> int:
    a, b := 0, 1
    for 0..n:
        a, b = b, a + b
    return a
test.eq(6765, fib(20))

--cytest: pass
