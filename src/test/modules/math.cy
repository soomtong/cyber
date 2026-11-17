use m 'math'
use t 'test'
use meta

t.eq_near(3.14159265, m.pi)
t.eq_near(0.69314718, m.ln2)
t.eq_near(2.30258509, m.ln10)
t.eq_near(1.44269504, m.log2e)
t.eq_near(0.43429448, m.log10e)
t.eq_near(2.71828182, m.e)
t.eq_near(0.70710678, m.sqrt1_2)
t.eq_near(1.41421356, m.sqrt2)

-- nan
t.eq(true,  m.is_nan(m.nan))
t.eq(false, m.is_nan(1))
t.eq(false, m.nan == m.nan)
t.eq(true,  m.nan != m.nan)
t.eq(false, m.nan == m.nan + 1)
t.eq(true,  m.nan != m.nan + 1)

t.eq(1.0, m.abs(1))
t.eq(1.0, m.abs(-1))
t.eq(0.0, m.ceil(0))
t.eq(1.0, m.ceil(0.1))
t.eq(0.0, m.floor(0))
t.eq(0.0, m.floor(0.1))
t.eq(0.0, m.round(0))
t.eq(0.0, m.round(0.1))
t.eq(1.0, m.round(0.5))
t.eq(1.0, m.trunc(1.12))
t.eq(-1.0, m.trunc(-1.12))
t.eq(2.0, m.max(1, 2))
t.eq(3.0, m.max(3, 2))
t.eq(1.0, m.min(1, 2))
t.eq(2.0, m.min(3, 2))
t.eq(1.0, m.sign(2))
t.eq(0.0, m.sign(0))
t.eq(-1.0, m.sign(-2))

if meta.is_vm_target():
    t.eq(31.0, m.clz32(1))
    t.eq(30.0, m.clz32(2))
    t.eq(0.0, m.clz32(-1))
    t.eq(0.0, m.clz32(-2))
    t.eq(6.0, m.mul32(2, 3))
    t.eq(-2.0, m.mul32(2147483647, 2))

    -- random
    rand := m.random()
    t.eq(true, rand >= 0 and rand < 1)
    -- Two values of one sequence differ.
    t.eq(true, m.random() != m.random())

t.eq(1.0, m.exp(0))
t.eq_near(2.7182818, m.exp(1))
t.eq_near(0.36787944, m.exp(-1))
t.eq_near(7.38905609, m.exp(2))
t.eq(0.0, m.expm1(0))
t.eq_near(1.7182818, m.expm1(1))
t.eq_near(-0.63212055, m.expm1(-1))
t.eq_near(6.38905609, m.expm1(2))
t.eq(3.0, m.log(2, 8))
t.eq(2.0, m.log(10, 100))
t.eq(0.0, m.ln(1))
t.eq_near(2.302585092, m.ln(10))

-- log1p
t.eq_near(0.6931471805, m.log1p(1))
t.eq(0.0, m.log1p(0))
t.eq(m.neginf, m.log1p(-1))
t.eq(true, m.is_nan(m.log1p(-2)))

-- log10
t.eq(5.0, m.log10(100000))
t.eq_near(0.30102999, m.log10(2))
t.eq(0.0, m.log10(1))
t.eq(m.neginf, m.log10(0))

-- log2
t.eq_near(1.5849625007, m.log2(3))
t.eq(1.0, m.log2(2))
t.eq(0.0, m.log2(1))
t.eq(m.neginf, m.log2(0))

-- pow
t.eq(343.0, m.pow(7, 3))
t.eq(2.0, m.pow(4, 0.5))
t.eq_near(0.020408163, m.pow(7, -2))
t.eq(true, m.is_nan(m.pow(-7, 0.5)))

-- hypot
t.eq(5.0, m.hypot(3, 4))
t.eq(13.0, m.hypot(5, 12))

-- sqrt
t.eq(2.0, m.sqrt(4))
t.eq(3.0, m.sqrt(9))

-- cbrt
t.eq(2.0, m.cbrt(8))
t.eq(3.0, m.cbrt(27))

-- cos
t.eq(-1.0, m.cos(m.pi))
t.eq(1.0, m.cos(0))

-- sin
t.eq_near(0.0, m.sin(m.pi))
t.eq_near(1.0, m.sin(m.pi/2))

-- tan
t.eq_near(0.0, m.tan(0))
t.eq_near(1.0, m.tan(m.pi/4))

-- cosh
t.eq(1.0, m.cosh(0))
t.eq_near(1.54308063, m.cosh(1))
t.eq_near(1.54308063, m.cosh(-1))
t.eq_near(3.76219569, m.cosh(2))

-- sinh
t.eq(0.0, m.sinh(0))
t.eq_near(1.17520119, m.sinh(1))
t.eq_near(-1.17520119, m.sinh(-1))
t.eq_near(3.6268604, m.sinh(2))

-- tanh
t.eq_near(-0.76159415, m.tanh(-1))
t.eq(0.0, m.tanh(0))
t.eq(1.0, m.tanh(m.inf))
t.eq_near(0.76159415, m.tanh(1))

-- acos
t.eq(0.0, m.acos(1))

-- asin
t.eq_near(m.pi/2, m.asin(1))

-- atan
t.eq(0.0, m.atan(0))
t.eq_near(0.7853981, m.atan(1))

-- atan2
t.eq(0.0, m.atan2(0, 0))

-- acosh
t.eq(true, m.is_nan(m.acosh(0.999999999999)))
t.eq(0.0, m.acosh(1))
t.eq_near(1.31695789, m.acosh(2))
t.eq_near(1.56679923, m.acosh(2.5))

-- asinh
t.eq_near(0.88137358, m.asinh(1))
t.eq(0.0, m.asinh(0))
t.eq_near(-0.88137358, m.asinh(-1))
t.eq_near(1.44363547, m.asinh(2))

-- atanh
t.eq(m.neginf, m.atanh(-1))
t.eq(0.0, m.atanh(0))
t.eq_near(0.54930614, m.atanh(0.5))
t.eq(m.inf, m.atanh(1))

-- is_inf
t.eq(true, m.is_inf(m.inf))
t.eq(true, m.is_inf(m.neginf))
t.eq(false, m.is_inf(m.nan))
t.eq(false, m.is_inf(123.0))

-- is_int
t.eq(true, m.is_int(1.0))
t.eq(true, m.is_int(40000000.0))
t.eq(false, m.is_int(40000000.1))
t.eq(false, m.is_int(40000000.01))
t.eq(false, m.is_int(40000000.001))
t.eq(false, m.is_int(m.nan))
t.eq(false, m.is_int(m.inf))

-- frac
t.eq_near(0.0, m.frac(1.0))
t.eq_near(0.0, m.frac(40000000.0))
t.eq_near(0.6, m.frac(40000000.6))
t.eq_near(0.1, m.frac(40000000.1))
t.eq_near(0.01, m.frac(40000000.01))
t.eq_near(0.001, m.frac(40000000.001))

-- Host function as a value.
sqrt_fn := m.sqrt
t.eq(4.0, sqrt_fn(16.0))
abs_fn := m.abs
t.eq(2.5, abs_fn(-2.5))

--cytest: pass