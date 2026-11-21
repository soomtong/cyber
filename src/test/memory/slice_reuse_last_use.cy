use test

fn drop_at(xs []int, n int) -> []int:
    return xs.removed(n)

fn positive(n int):
    test.eq(true, n > 0)

-- A new-list method of `Slice` on the last use of a local reuses its buffer. The result is the same.
-- See `docs/decisions/project_last_use.md` "B".

fn run():
    -- `removed` on the last use keeps the buffer.
    xs := []int{1, 2, 3}
    p := as[int] xs.ptr
    ys := xs.removed(0)
    test.eq(true, p == as[int] ys.ptr)
    test.eq(2, ys.len())
    test.eq(2, ys[0])

    -- Another value that shares the buffer is unchanged.
    a := []str{'x'.repeat(40), 'y'}
    b := a
    c := a.appended('z')
    test.eq(2, b.len())
    test.eq(3, c.len())
    test.eq(40, b[0].len())

    -- `inserted`, `appended` and `+` in a row.
    d := []int{2}
    e := d.inserted(0, 1)
    f := e.appended(3)
    g := f + []int{4}
    test.eq(4, g.len())
    test.eq(4, g[3])

    -- A local that the statement names twice, or that a later statement names, is copied.
    h := []int{9}
    i := h.appended(h.len())
    test.eq(2, i.len())
    j := []int{7}
    k := j.appended(8)
    test.eq(1, j.len())
    test.eq(2, k.len())

    -- The result shares its buffer with no other value, also when the in-place method does not copy:
    -- `remove` of the last element, and `append` of an empty span.
    m := []int{1, 2, 3}
    n := m
    o := m.removed(2)
    o[0] = 9
    test.eq(1, n[0])
    m2 := []int{1, 2, 3}
    n2 := m2
    o2 := m2 + []int{}
    o2[0] = 9
    test.eq(1, n2[0])
    -- A parameter shares the buffer of the argument.
    m3 := []int{1, 2, 3}
    o3 := drop_at(m3, 2)
    o3[0] = 9
    test.eq(1, m3[0])
    -- A sub-slice views the buffer of its parent.
    big := []int{1, 2, 3, 4}
    sub := big[1..3]
    o4 := sub.removed(1)
    o4[0] = 99
    test.eq(2, big[1])

    -- The argument of an overloaded function: a candidate that does not match leaves the local alive.
    out := []int{}
    q := []int{1}
    out += q.appended(2)
    test.eq(2, out.len())
    q2 := []int{1}
    out.append(q2.appended(2))
    test.eq(4, out.len())
    q3 := []int{1}
    r3 := out + q3.appended(2)
    test.eq(6, r3.len())
    q4 := []str{'a'}
    test.eq('2', str(q4.appended('b').len()))

    -- The body of `#for` is checked once for each iteration: no reuse.
    t := []int{1}
    #for 0..2 |i|:
        positive(t.appended(i).len())

run()

--cytest: pass
