use test
use math

-- A float always converts to text that reads back as a float.
-- A finite value without a fraction gets `.0`.

-- Integral.
test.eq(str(3.0), '3.0')
test.eq(str(0.0), '0.0')
test.eq(str(100.0), '100.0')
test.eq(str(float(7)), '7.0')
test.eq(str(1.0 + 2), '3.0')

-- Fractional. The digits are the shortest that read back as the same value.
test.eq(str(1.5), '1.5')
test.eq(str(0.1), '0.1')
test.eq(str(123.456), '123.456')
test.eq(str(0.1 + 0.2), '0.30000000000000004')

-- Negative.
test.eq(str(-2.0), '-2.0')
test.eq(str(-2.5), '-2.5')
test.eq(str(-0.0), '-0.0')

-- Large and small values written with an exponent print as plain decimals.
test.eq(str(1e21), '1000000000000000000000.0')
test.eq(str(1.5e10), '15000000000.0')
test.eq(str(9007199254740993.0), '9007199254740992.0')
test.eq(str(1e-7), '0.0000001')
test.eq(str(-2.5e-3), '-0.0025')

-- Infinity and NaN stay as they are.
test.eq(str(math.inf), 'inf')
test.eq(str(-math.inf), '-inf')
test.eq(str(math.nan), 'nan')

-- fmt() is the same text.
test.eq(3.0.fmt(), '3.0')
test.eq(1.5.fmt(), '1.5')
test.eq(math.inf.fmt(), 'inf')

-- f32.
test.eq(str(f32(3)), '3.0')
test.eq(str(f32(0.1)), '0.1')
test.eq(str(f32(-2.5)), '-2.5')
test.eq(f32(16777216).fmt(), '16777216.0')

-- String interpolation.
x := 3.0
test.eq('%{x}', '3.0')
test.eq('a=%{2.0 * 2} b=%{0.5} c=%{f32(1)}', 'a=4.0 b=0.5 c=1.0')

-- The text reads back as the same float.
test.eq(float.parse(str(3.0))!, 3.0)
test.eq(float.parse(str(1e21))!, 1e21)

-- An int does not get a fraction.
test.eq(str(3), '3')
test.eq('%{int(3.0)}', '3')

-- Inside a slice, a map, an option and a record.
type Point:
    x float
    y f32

test.eq(to_print_string([]float{3, 5.5}), '{3.0, 5.5}')
test.eq(to_print_string([]f32{1, 0.25}), '{1.0, 0.25}')
test.eq(to_print_string(Point{x=1, y=2}), 'Point{x=1.0, y=2.0}')
var opt ?float = 2.0
test.eq(to_print_string(opt), '2.0')
m := Map[str, float]{}
m['a'] = 4.0
test.eq(to_print_string(&m), "{'a': 4.0}")

--cytest: pass
