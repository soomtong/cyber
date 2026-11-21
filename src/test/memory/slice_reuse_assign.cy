use test

-- `xs = xs.appended(v)` reuses the buffer of `xs`: the receiver is the last use of the old value. From a loop body too.
-- See `docs/decisions/project_last_use.md` "이동한 지역에 다시 대입".

fn run():
    xs := []int{1}
    xs = xs.appended(2)
    p := as[int] xs.ptr
    xs = xs.removed(0)
    test.eq(true, p == as[int] xs.ptr)

    -- A loop grows the buffer a few times, not once for each element.
    q := as[int] xs.ptr
    grown := 0
    for 0..100 |i|:
        xs = xs.appended(i)
        if as[int] xs.ptr != q:
            grown += 1
            q = as[int] xs.ptr
    test.eq(101, xs.len())
    test.eq(99, xs[100])
    test.eq(true, grown < 10)

    -- Another value that shares the buffer is unchanged.
    ys := xs
    xs = xs.appended(7)
    test.eq(101, ys.len())
    test.eq(102, xs.len())
    xs = xs.removed(0)
    test.eq(2, ys[0])
    test.eq(0, xs[0])

    -- `+` and `inserted`.
    zs := []int{2}
    zs = zs + []int{3}
    zs = zs.inserted(0, 1)
    test.eq(3, zs.len())
    test.eq(1, zs[0])
    test.eq(3, zs[2])

    -- The right side names the local twice: a copy.
    zs = zs.appended(zs.len())
    test.eq(3, zs[3])

    -- Managed elements, in a `while` loop.
    strs := []str{}
    n := 0
    while n < 50:
        strs = strs.appended('s%{n}'.repeat(3))
        n += 1
    test.eq(50, strs.len())
    test.eq('s49s49s49', strs[49])

run()

--cytest: pass
