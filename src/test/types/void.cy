use test

-- Initialize void.
a := _
test.eq_type(void, type.of(a))
test.eq(_, a)

--cytest: pass