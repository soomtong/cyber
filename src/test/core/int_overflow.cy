use test

-- `+`, `-`, `*`, `**`, unary `-` and `/` of a signed integer panic with 'Integer overflow.' when the result does not
-- fit in its type. These are the results that do fit, and the methods that wrap or report instead.
max := int.max
min := int.min
test.eq(max, (max - 1) + 1)
test.eq(min, (min + 1) - 1)
test.eq(-max, min + 1)
test.eq(9223372030926249001, 3037000499 * 3037000499)
test.eq(4611686018427387904, 2 ** 62)
test.eq(-max, max / -1)
-- The remainder by -1 is 0, also of the smallest value.
test.eq(0, min % -1)
test.eq(i8(127), i8(100) + i8(27))
test.eq(i8(-128), i8(-100) - i8(28))
test.eq(i32(2147483647), i32(46340) * i32(46340) + i32(88047))

-- Wrapping at the width of the type.
test.eq(min, max.wrapping_add(1))
test.eq(max, min.wrapping_sub(1))
test.eq(-2, max.wrapping_mul(2))
test.eq(i8(-56), i8(100).wrapping_add(i8(100)))
test.eq(i16(-32768), i16(-1).wrapping_mul(i16(-32768)))

-- `none` when the result does not fit.
test.eq(true, max.checked_add(1) == none)
test.eq(max - 1, max.checked_add(-1).?)
test.eq(true, min.checked_sub(1) == none)
test.eq(-2, (5).checked_sub(7).?)
test.eq(true, min.checked_mul(-1) == none)
test.eq(true, (-1).checked_mul(min) == none)
test.eq(true, (3037000500).checked_mul(3037000500) == none)
test.eq(i8(127), i8(100).checked_add(i8(27)).?)
test.eq(true, i8(100).checked_add(i8(28)) == none)
test.eq(true, i32(46341).checked_mul(i32(46341)) == none)

-- `Raw` integers wrap: they are bits for masks and memory.
test.eq(r8(44), r8(200) + r8(100))
test.eq(r64(0), r64(0xffffffffffffffff) + r64(1))

-- At compile time the same results fold.
const k = 9223372036854775806 + 1
test.eq(max, k)

--cytest: pass
