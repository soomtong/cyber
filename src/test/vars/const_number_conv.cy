use test

-- `float(n)` and `int(x)` work in a const, as at runtime.
const Years = 50
const MaxYears = float(Years)
test.eq(MaxYears, 50.0)
const Half = f32(1) / 2
test.eq(Half, f32(0.5))
const Whole = int(2.9)
test.eq(Whole, 2)
const Down = int(-2.9)
test.eq(Down, -2)
const One = int(true)
test.eq(One, 1)

--cytest: pass
