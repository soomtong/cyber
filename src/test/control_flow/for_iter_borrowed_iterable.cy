use test

-- A borrowed iterable is iterated in place, like `for a.* |x|:`.
fn total(a &[]int) -> int:
    s := 0
    for a |x|:
        s += x
    return s

fn total_arr(a &Array[int]) -> int:
    s := 0
    for a |i, x|:
        s += i * x
    for a.* |x|:
        s += x
    return s

fn lens(a &Array[str]) -> int:
    s := 0
    for a |&x|:
        s += x.len()
    return s

b := []int{1, 2, 3}
test.eq(6, total(&b))
test.eq(3, b.len())

c := Array[int]{1, 2, 3}
test.eq(14, total_arr(&c))
test.eq(3, c.len())

d := Array[str]{'a', 'bc'}
test.eq(3, lens(&d))

m := Map[str, int]{a=1}
mb := &m
n := 0
for mb |e|:
    n += e.value
test.eq(1, n)

--cytest: pass
