use test

-- An arithmetic operator or a comparison with an integer and a float converts the integer,
-- whichever side it is on. `f32` and `float` convert to `float` the same way.

i := 7
f := 2.5
var g f32 = 1.5
var s i8 = 3
var b byte = 3
var r r64 = 5

-- Arithmetic, float on the left (as before).
test.eq(17.5, f * i)
test.eq(9.5, f + i)
test.eq(-4.5, f - i)
test.eq(12.5, f * r)

-- Arithmetic, integer on the left.
test.eq(17.5, i * f)
test.eq(9.5, i + f)
test.eq(4.5, i - f)
test.eq(2.8, i / f)
test.eq(2.0, i % f)
test.eq(49.0, i ** 2.0)
test.eq(12.5, r * f)
test.eq(5.5, b + f)
test.eq(17.5, i * 2.5)
test.eq(-17.5, -i * f)
test.eq(20.0, (i + 1) * f)

-- The result has the type of the float operand.
var w f32 = s * g
test.eq(f32(4.5), w)
w = g * s
test.eq(f32(4.5), w)
w = i * g
test.eq(f32(10.5), w)

-- `f32` with `float` gives `float`.
test.eq(3.75, g * f)
test.eq(3.75, f * g)
test.eq(4.0, g + f)
test.eq(1.0, f - g)

-- Integer division happens before the conversion.
var half float = i / 2
test.eq(3.0, half)
test.eq(3.5, i / 2.0)

-- Comparisons.
test.eq(false, i < f)
test.eq(false, i <= f)
test.eq(true, i > f)
test.eq(true, i >= f)
test.eq(false, i == f)
test.eq(true, i != f)
test.eq(true, f < i)
test.eq(true, i == 7.0)
test.eq(true, 7.0 == i)
test.eq(true, 2 < f)
test.eq(true, i * 1.0 == i)
test.eq(true, g < f)
test.eq(false, g == f)
test.eq(true, g != f)
test.eq(true, r > f)

-- An integer of another width on the right of a comparison.
test.eq(true, s < i)
test.eq(false, i < s)
test.eq(false, s == i)
test.eq(true, b < i)
test.eq(true, s == 3)

-- The left operand is evaluated once and before the right one.
global order str = ''
fn left_int() -> int:
    order += 'L'
    return 3
fn right_float() -> float:
    order += 'R'
    return 2.5
test.eq(7.5, left_int() * right_float())
test.eq(false, left_int() < right_float())
test.eq('LRLR', order)

-- Compound assignment to a float.
acc := 1.5
acc += i
acc *= 2
test.eq(17.0, acc)

-- Fields, elements and calls.
type P:
    n int
    w float
p := P{n=3, w=1.5}
xs := []int{1, 2, 3}
test.eq(4.5, p.n * p.w)
test.eq(2.0, xs[2] / p.w)
test.eq(1.5, xs.len() * 0.5)

fn area(radius int) -> float:
    return radius * radius * 3.5
test.eq(14.0, area(2))

-- Compile-time evaluation follows the same rule.
const k = 3
const h = 1.5
const k_lit = k * 2.5
const lit_k = 2.5 * k
const k_h = k * h
const h_k = h * k
test.eq(7.5, k_lit)
test.eq(7.5, lit_k)
test.eq(4.5, k_h)
test.eq(4.5, h_k)

--cytest: pass
