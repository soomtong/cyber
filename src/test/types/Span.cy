use t 'test'

-- Span literal assigned to a new local. The hidden vector outlives the statement.
sp := [&]int{1, 2, 3}
t.eq(3, sp.len())
t.eq(1, sp[0])
t.eq(3, sp[2])
t.eq_span([&]int{1, 2, 3}, sp)

-- Span literal assigned to an existing local.
var sp2 [&]int = [&]int{9}
sp2 = [&]int{4, 5}
t.eq(2, sp2.len())
t.eq(5, sp2[1])

-- Span literal in a function.
fn sum3() -> int:
    s := [&]int{10, 20, 30}
    return s[0] + s[1] + s[2]
t.eq(60, sum3())

-- Span literal of strings.
names := [&]str{'a', 'bc'}
t.eq('bc', names[1])
t.eq(2, names.len())

-- Slicing a span literal local.
t.eq_span([&]int{2, 3}, sp[1..])

--cytest: pass
