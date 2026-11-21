use test

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

run()

--cytest: pass
