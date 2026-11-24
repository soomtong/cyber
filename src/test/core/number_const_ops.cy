use test

-- A `const` evaluates its operators at compile time. Each value is the one the same operator gives at runtime:
-- an integer wraps at its width, `/` truncates, `>>` is a logical shift, and a shift uses the low 6 bits of its amount.

-- Runtime operands.
i := 7
n := -7
big := 9223372036854775807
var s8 i8 = 100
var m8 i8 = -8
var t8 i8 = 3
var s16 i16 = 3
var s32 i32 = 5
var r8 r8 = 200
var r32 r32 = 7
var r64 r64 = 5
f := 2.5
var g f32 = 1.5

-- The same values as constants.
const ci = 7
const cn = -7
const cbig = 9223372036854775807
const cs8 i8 = 100
const cm8 i8 = -8
const ct8 i8 = 3
const cs16 i16 = 3
const cs32 i32 = 5
const cr8 r8 = 200
const cr32 r32 = 7
const cr64 r64 = 5
const cf = 2.5
const cg f32 = 1.5

-- `int`.
const i_mod = ci % 3
const n_div = cn / 2
const n_mod = cn % 2
const i_pow = ci ** 3
const pow_wrap = 2 ** 70
const pow_neg = ci ** -1
const big_add = cbig + 1
const min_div = (-cbig - 1) / -1
const min_mod = (-cbig - 1) % -1
const i_le = ci <= 7
const i_ge = ci >= 8
const i_and = ci && 3
const i_or = ci || 8
const i_xor = ci ~ 2
const i_shr = cn >> 60
const i_shl = 1 << 70
test.eq(i % 3, i_mod)
test.eq(n / 2, n_div)
test.eq(n % 2, n_mod)
test.eq(i ** 3, i_pow)
test.eq(0, pow_wrap)
test.eq(i ** -1, pow_neg)
test.eq(big + 1, big_add)
test.eq(-big - 1, min_div)
test.eq(0, min_mod)
test.eq(i <= 7, i_le)
test.eq(i >= 8, i_ge)
test.eq(i && 3, i_and)
test.eq(i || 8, i_or)
test.eq(i ~ 2, i_xor)
test.eq(n >> 60, i_shr)
test.eq(64, i_shl)

-- Narrow integers wrap at their width.
const s8_add = cs8 + cs8
const s8_mul = cs8 * 3
const s8_pow = ct8 ** 5
const m8_shr = cm8 >> 1
const m8_div = cm8 / 3
const s8_lt = cm8 < cs8
const s16_mul = cs16 * 4
const s32_sub = cs32 - 9
const s32_le = cs32 <= 2
const r8_add = cr8 + cr8
const r8_gt = cr8 > 100
const r32_div = cr32 / 2
const r32_mod = cr32 % 4
test.eq(s8 + s8, s8_add)
test.eq(s8 * 3, s8_mul)
test.eq(t8 ** 5, s8_pow)
test.eq(m8 >> 1, m8_shr)
test.eq(m8 / 3, m8_div)
test.eq(m8 < s8, s8_lt)
test.eq(s16 * 4, s16_mul)
test.eq(s32 - 9, s32_sub)
test.eq(s32 <= 2, s32_le)
test.eq(r8 + r8, r8_add)
test.eq(r8 > 100, r8_gt)
test.eq(r32 / 2, r32_div)
test.eq(r32 % 4, r32_mod)

-- The narrower integer widens, whichever side it is on.
const wide_l = ci * cs8
const wide_r = cs8 * ci
const wide_raw = cr8 + cr64
const raw_lt = cr64 < cm8
test.eq(i * s8, wide_l)
test.eq(s8 * i, wide_r)
test.eq(r8 + r64, wide_raw)
test.eq(r64 < m8, raw_lt)

-- Floats.
const f_add = cf + 1.0
const f_sub = cf - 0.5
const f_div = cf / 2.0
const f_mod = cf % 1.0
const f_pow = cf ** 2.0
const f_lt = cf < 3.0
const f_eq = cf == 2.5
const f_ne = cf != 2.5
const g_add = cg + 2.5
const g_mul = cg * cg
const i_f = ci + cf
const f_i = cf + ci
const i_eq_f = ci == 7.0
test.eq(f + 1.0, f_add)
test.eq(f - 0.5, f_sub)
test.eq(f / 2.0, f_div)
test.eq(f % 1.0, f_mod)
test.eq(f ** 2.0, f_pow)
test.eq(f < 3.0, f_lt)
test.eq(true, f_eq)
test.eq(false, f_ne)
test.eq(g + 2.5, g_add)
test.eq(g * g, g_mul)
test.eq(i + f, i_f)
test.eq(f + i, f_i)
test.eq(true, i_eq_f)

-- A constant of `symbol` is a value at compile time too.
const sym = symbol.a
const sym_eq = sym == symbol.a
const sym_ne = sym != symbol.a
test.eq(true, sym_eq)
test.eq(false, sym_ne)

--cytest: pass
