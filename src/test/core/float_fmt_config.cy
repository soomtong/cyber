use test

-- `places` gives that many digits after the point.
test.eq(1234.5.fmt({places=2}), '1234.50')
test.eq(3.0.fmt({places=0}), '3')
test.eq(0.5.fmt({places=3}), '0.500')
test.eq((-0.004).fmt({places=2}), '-0.00')
test.eq(1e21.fmt({places=1}), '1000000000000000000000.0')

-- It rounds the digits that `fmt()` shows, half away from zero.
test.eq(2.675.fmt({places=2}), '2.68')
test.eq(1.005.fmt({places=2}), '1.01')
test.eq(0.125.fmt({places=2}), '0.13')
test.eq(9.995.fmt({places=2}), '10.00')
test.eq((-2.5).fmt({places=0}), '-3')

-- Without `places`, the digits are those of `fmt()`.
test.eq(0.1.fmt({}), '0.1')
test.eq(3.0.fmt({}), '3.0')

-- `sep` groups the digits before the point only.
test.eq(1234567.891.fmt({places=2, sep=','}), '1,234,567.89')
test.eq((-1234567.25).fmt({sep=','}), '-1,234,567.25')
test.eq(999.999.fmt({places=2, sep=','}), '1,000.00')
test.eq(0.123456.fmt({sep=','}), '0.123456')
test.eq(1234.5.fmt({places=1, sep='_'}), '1_234.5')

-- `width` and `pad` work as for integers; a `0` pad goes after the sign.
test.eq(4.5.fmt({places=2, width=8}), '    4.50')
test.eq((-4.5).fmt({places=2, pad='0', width=8}), '-0004.50')
test.eq(1234.5.fmt({places=2, sep=',', width=10, pad='*'}), '**1,234.50')

-- Infinity and NaN keep their names.
test.eq((1.0 / 0.0).fmt({places=2, sep=','}), 'inf')
test.eq((-1.0 / 0.0).fmt({places=2}), '-inf')

-- f32 rounds its own digits.
test.eq((as[f32] 0.1).fmt({places=3}), '0.100')
test.eq((as[f32] 1234.5).fmt({places=1, sep=','}), '1,234.5')

--cytest: pass
