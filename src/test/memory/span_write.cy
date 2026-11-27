use test

-- A value that is not managed is written in place through a span, as through a `&T`.
fn zero_first(xs [&]int):
    xs[0] = 0

xs := []int{1, 2, 3}
zero_first(xs.span())
test.eq(0, xs[0])
zero_first(xs[1..].span())
test.eq(0, xs[1])

-- Managed elements are replaced through the slice taken as `&&[]T`.
fn rename(names &&[]str):
    names[0] = 'z'
    names.append('c')

names := []str{'a', 'b'}
rename(&&names)
test.eq(3, names.len())
test.eq('z', names[0])

--cytest: pass
