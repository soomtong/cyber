use t 'test'

-- Host functions own their `str` params and must release them.
-- Heap strings (built by concatenation) make a missing release show up as an unreleased refcount.
num := '1' + '2.5'
t.eq(12.5, float(num))
t.eq(f32(12.5), f32(num))
-- Like C `atof`, a string that does not parse gives 0.
bad := ' ' + num
t.eq(0.0, float(bad))

needle := 'c' + 'd'
t.eq(2, 'abcde'.index(needle).?)

ins := 'X' + 'Y'
t.eq('aXYbc', 'abc'.insert(1, ins))

--cytest: pass
