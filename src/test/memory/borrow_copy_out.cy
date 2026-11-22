use test

-- A copy of a borrow that is read out of a borrow container (`h.b`, `xs[i]`) borrows what the container borrows, so it
-- can outlive the container.

type Inner:
    b &int

type H:
    a &int
    b &int
    inner Inner
    o ?&int

type O:
    b &int

fn run():
    y := 5
    x := 7
    var r &int = &x
    var ri Inner = Inner{b=&x}
    var ro ?&int = none
    var o O = O{b=&x}
    if true:
        h := H{a=&y, b=&y, inner=Inner{b=&y}, o=&y}
        r = h.b
        test.eq(5, r.*)
        r = h.inner.b
        ri = h.inner
        ro = h.o
        o.b = h.b
    test.eq(5, r.*)
    test.eq(5, ri.b.*)
    test.eq(5, ro.?.*)
    test.eq(5, o.b.*)

    -- Elements of a vector of borrows, by a constant and by a computed index.
    z := 9
    if true:
        xs := [2]&int{&y, &z}
        r = xs[0]
        test.eq(5, r.*)
        var i int = 1
        r = xs[i]
    test.eq(9, r.*)

    -- A vector of containers.
    if true:
        hs := [1]H{H{a=&z, b=&z, inner=Inner{b=&z}, o=none}}
        r = hs[0].inner.b
    test.eq(9, r.*)

    -- A borrow that is stored in the container later is a loan of it, and the copy keeps it.
    if true:
        var h H = H{a=&y, b=&y, inner=Inner{b=&y}, o=none}
        h.b = &z
        r = h.b
    test.eq(9, r.*)

    -- An unwrap capture of an option in a container borrows what the container borrows.
    if true:
        h := H{a=&y, b=&y, inner=Inner{b=&y}, o=&z}
        if h.o |q|:
            r = q
    test.eq(9, r.*)

run()

--cytest: pass
