use test
use math
use meta

-- Default notation.
test.eq(1.0, 1.0)
test.eq(-1.0, -1.0)
test.eq(1.0, -(-1.0))

-- Scientific notation.
test.eq(123.0, 1.23e2)
test.eqNear(1.23, 123e-2)

-- float.$init()
test.eq(100.0, float(100))
test.eq(100.1, float(100.1))
if meta.is_vm_target():
    test.eq(100.0, float('100'))
    test.eq(100.1, float('100.1'))
test.eq(1.0, float(true))
test.eq(0.0, float(false))

-- `_` between digits is ignored.
test.eq(1_000.5, 1000.5)
test.eq(1.000_5, 1.0005)
test.eq(1_0e1_0, 10e10)

-- Infinity.
test.eq(math.inf, 1.0 / 0)

-- NaN.
test.eq(true, math.isNaN(0.0 * (1.0 / 0)))

-- Hex, octal and binary literals convert by their value when the target is a float.
var hex_f float = 0x10
test.eq(hex_f, 16.0)
var oct_f f32 = 0o17
test.eq(oct_f, f32(15.0))
var bin_f float = -0b101
test.eq(bin_f, -5.0)
var opt_f ?float = 0xff
test.eq(opt_f.?, 255.0)
test.eq(float((0x7fffffffffffffff)), 9223372036854775807.0)

-- A raw integer is unsigned at every width.
var raw_max r64 = 0xffffffffffffffff
test.eq(float(raw_max), 18446744073709551615.0)
test.eq(f32(raw_max), f32(18446744073709551615.0))
var raw_high r64 = 0x8000000000000000
test.eq(float(raw_high), 9223372036854775808.0)
var raw_f float = raw_high
test.eq(raw_f, 9223372036854775808.0)
test.eq(float(r32(0xffffffff)), 4294967295.0)
test.eq(float(byte(200)), 200.0)
test.eq(float(-1), -1.0)

-- A float converts to a raw integer by its unsigned value. The fraction is dropped.
test.eq(r64(18446744073709549568.0), 0xfffffffffffff800)
test.eq(r64(9223372036854775808.0), 0x8000000000000000)
test.eq(r64(3.7), 3)
test.eq(r32(4294967295.0), 0xffffffff)
test.eq(byte(255.9), 255)
test.eq(r64(f32(3.7)), 3)
test.eq(r16(f32(3.7)), 3)

--cytest: pass