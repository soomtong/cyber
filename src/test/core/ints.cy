use t 'test'
use meta

-- @init()
res := int('100')
t.eqType(int, type.of(res))
t.eq(0, int('100.1'))
t.eq(100, res)
t.eq(100, int(100.1))

-- Once a numeric literal is assigned to untyped local, it becomes an integer.
a := 10
t.eq(a, 10)

-- Hex notation.
t.eq(0xff, 255)
t.eq(0xFF, 255)

-- Octal notation.
t.eq(0o77, 63)

-- Binary notation.
t.eq(0b11, 3)

-- `_` between digits is ignored.
t.eq(100_000, 100000)
t.eq(1_2_3, 123)
t.eq(0xff_ff, 65535)
t.eq(0o7_7, 63)
t.eq(0b1111_0000, 240)
t.eq(1_000u, 1000u)
const PARAM_CAP r32 = 100_000
t.eq(PARAM_CAP, r32(100000))
t.eq(-1_000, -1000)
t.eq(1_000.fmt(), '1000')

-- Infer UTF-8 code point.
t.eq(97, 'a')
t.eq(65, 'A')
t.eq(39, '\'')    -- Escape single quote.
t.eq(92, '\\')    -- Escape backslash.
t.eq(128054, '🐶')
t.eq(129418, '🦊')
t.eq(10, '\n')

-- Equals.
t.eq(3 == 2, false)
t.eq(3 == 3, true)

-- Not equals.
t.eq(3 != 2, true)
t.eq(3 != 3, false)

-- Comparisons.
t.eq(1 < 2, true)
t.eq(2 < 1, false)
t.eq(1 > 2, false)
t.eq(2 > 1, true)
t.eq(1 <= 2, true)
t.eq(2 <= 2, true)
t.eq(3 <= 2, false)
t.eq(1 >= 2, false)
t.eq(2 >= 2, true)
t.eq(3 >= 2, true)

-- Bitwise and.
t.eq(4 && 2, 0)
t.eq(4 && 4, 4)
t.eq(7 && 2, 2)
-- A constant right operand that does not fit i16 (`and_64`).
big := -1
t.eq(big && ~(3 << 62), 4611686018427387903)
t.eq(big && 0xFF00, 0xFF00)
t.eq(0xF0F0 && ~0xFF00, 0xF0)
t.eq(big && 0, 0)

-- Bitwise or.
t.eq(4 || 2, 6)
t.eq(4 || 4, 4)

-- Bitwise xor.
t.eq(4 ~ 2, 6)
t.eq(4 ~ 4, 0)

-- Bitwise not.
t.eq(~0, -1)
t.eq(~(-1), 0)
t.eq(~1, -2)

-- Bitwise right shift (logical).
t.eq(4, 16 >> 2)
t.eq(0, 2 >> 2)
t.eq(1, -1 >> 63)
t.eq(0x40000000, 0x80000000 >> 1)
t.eq(1, 0x8000000000000000 >> 63)

use math

-- Bitwise left shift (logical).
t.eq(32, 2 << 4)
t.eq(int.min, 1 << 63)
t.eq(0, int.min << 1)  

-- fmt()
t.eq(122.fmt(.dec), '122')
if meta.is_vm_target():
    t.eq(122.fmt(.bin), '1111010')
    t.eq(122.fmt(.oct), '172')
    t.eq(122.fmt(.hex), '7a')
    t.eq(122.fmt(.ch), 'z')
    -- t.eq(2.fmt(.bin, {pad=`0`, width=8}), '00000010')
    -- t.eq(8.fmt(.oct, {pad=`0`, width=3}), '010')
    -- t.eq(10.fmt(.dec, {pad=`0`, width=4}), '0010')
    -- t.eq(16.fmt(.hex, {pad=`0`, width=4}), '0010')

-- -- Implicit widen.
-- a_int := as[int] i32(-123)
-- t.eq(-123, a_int)

-- Truncate.
a = 123
t.eq(byte(123), byte(a))

-- r64.decode()
vec := [8]byte{0x5a, 0xf1, 0x06, 0x04, 0x5e, 0x23, 0x8d, 0xd2}
t.eq(0x5AF106045E238DD2, r64.decode(&vec, .big))
t.eq(0xD28D235E0406F15A, r64.decode(&vec, .little))

-- r32.decode()
vec2 := [4]byte{0x49, 0x96, 0x02, 0xD2}
t.eq(r32(0x499602D2), r32.decode(&vec2, .big))
t.eq(r32(0xD2029649), r32.decode(&vec2, .little))

-- parse()
t.eq(42, int.parse('42') !else 999)
t.eq(-5, int.parse('-5') !else 999)
t.eq(5, int.parse('+5') !else 999)
t.eq(0, int.parse('-0') !else 999)
t.eq(-128, i8.parse('-128') !else 99)
t.eq(9223372036854775807, i64.parse('9223372036854775807') !else 99)
fn parse_err(s str) -> error:
    v := int.parse(s) !else |err|:
        return err
    t.eq(0, v)
    return error.None
t.eq(error.InvalidCharacter, parse_err(''))
t.eq(error.InvalidCharacter, parse_err('-'))
t.eq(error.InvalidCharacter, parse_err('+'))
t.eq(error.InvalidCharacter, parse_err('abc'))
t.eq(error.InvalidCharacter, parse_err('1-2'))
t.eq(error.InvalidCharacter, parse_err('12a'))
t.eq(-7, int('-7'))
t.eq(0, int(''))
t.eq(0, int('abc'))

-- 64-bit literals. A plain decimal must fit in i64 (F-76); bit patterns use `u`, hex or an `r64` target.
t.eq(9223372036854775807, 9223372036854775807)
t.eq(-9223372036854775808, -9223372036854775808)
t.eq(-1, 18446744073709551615u)
t.eq(-1, 0xffffffffffffffff)
var full r64 = 18446744073709551615
t.eq(r64(0xffffffffffffffff), full)
var top i64 = 9223372036854775807
t.eq(9223372036854775807, top)

-- Narrow ints divide from their own sign bit.
t.eq(i8(-4), i8(-8) / i8(2))
t.eq(i8(-3), i8(-7) % i8(4))
t.eq(i16(-4), i16(-8) / i16(2))
t.eq(i16(-3), i16(-7) % i16(4))
t.eq(i32(-4), i32(-8) / i32(2))
t.eq(i32(-3), i32(-7) % i32(4))
t.eq(i32(4), i32(-8) / i32(-2))

-- Narrow ints, a wrapped sum divides as the wrapped value.
t.eq(i8(-28), (i8(100) + i8(100)) / i8(2))
t.eq(i8(-2), (i8(100) + i8(100)) % i8(3))
t.eq(i32(-1), (i32.max + i32(1)) / i32.max)

-- Narrow ints, `>>` shifts in zeros from their own width.
t.eq(i8(124), i8(-8) >> i8(1))
t.eq(i16(32764), i16(-8) >> i16(1))
t.eq(i32(2147483644), i32(-8) >> i32(1))
t.eq(i8(100), (i8(100) + i8(100)) >> i8(1))
t.eq(i8(15), (i8(-1) << i8(4)) >> i8(4))

-- Narrow ints, unsigned division.
t.eq(i32(2147483644), i32(-8).udiv(i32(2)))
t.eq(i32(15), i32(-1).umod(i32(16)))
t.eq(i8(100), (i8(100) + i8(100)).udiv(i8(2)))

-- Narrow ints, the operands keep their values after a division or shift.
narrow_a := i8(100) + i8(100)
narrow_b := i8(2)
t.eq(i8(-28), narrow_a / narrow_b)
t.eq(i8(100), narrow_a >> i8(1))
t.eq(i8(-56), narrow_a)
t.eq(i8(2), narrow_b)
t.eq(-56, int(narrow_a))

-- Narrow ints convert to a float from their own sign bit (F-84).
t.eq(-56.0, float(i8(100) + i8(100)))
t.eq(-56.0, float(narrow_a))
t.eq(-5536.0, float(i16(30000) + i16(30000)))
t.eq(-294967296.0, float(i32(2000000000) + i32(2000000000)))
t.eq(f32(-56.0), f32(narrow_a))
t.eq(-28.0, float(narrow_a) / 2.0)
t.eq(i8(-56), narrow_a)

-- Narrow ints, power (F-85).
t.eq(i8(8), i8(2) ** i8(3))
t.eq(i8(-8), i8(-2) ** i8(3))
t.eq(i8(0), i8(2) ** i8(-1))
t.eq(i8(1), i8(1) ** i8(-1))
t.eq(i8(-1), i8(-1) ** i8(-1))
t.eq(i16(81), i16(3) ** i16(4))
t.eq(i32(-27), i32(-3) ** i32(3))
t.eq(i8(0), i8(2) ** i8(8))
t.eq(1024, 2 ** 10)

-- `~` with a float target applies to the int operand (F-86).
not_x := 5
t.eq(-6.0, float(~not_x))
t.eq(-6.0, float(~5))
var not_f float = ~not_x
t.eq(-6.0, not_f)
fn take_float(a float) -> float:
    return a
t.eq(-4.0, take_float(~3))
var not_opt ?int = ~not_x
t.eq(-6, not_opt.?)

--cytest: pass