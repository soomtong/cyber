use test

-- What the checks of borrows of places in containers, of borrows through a borrow of a container and of `scope`
-- parameters stored behind another parameter still allow.

type W:
    x int
    q &int

type H:
    a &int
    b &int

type O:
    a &int
    o ?&int

type View:
    a &int

type Outer:
    v View

fn put(h &&H, scope p &int):
    h.b = p

fn (&&Outer) set(scope p &int):
    self.v = View{a=p}

fn forward(o &&Outer, scope p &int):
    o.set(p)

fn mk(scope p &int) -> scope H:
    h := H{a=p, b=p}
    return h

fn field_of(scope w &W) -> scope &int:
    return &w.x

fn run():
    y := 5
    z := 7

    -- A copy of a container with a borrow of a place in another container, in the same block.
    w := W{x=42, q=&z}
    h := H{a=&y, b=&w.x}
    h2 := h
    test.eq(42, h2.b.*)

    -- A copy of a borrow that is read through a borrow of a container that borrows only its owners can outlive it.
    var r &int = &y
    if true:
        h3 := H{a=&y, b=&z}
        hr := &h3
        r = hr.b
    test.eq(7, r.*)

    -- An unwrap capture of an option in a container that borrows only its owners.
    if true:
        var o O = O{a=&y, o=none}
        o.o = &z
        if o.o |q|:
            r = q
    test.eq(7, r.*)

    -- A container ends after the last use of a borrow of it.
    a := Array[int]{1, 2}
    if true:
        var h4 H = H{a=&y, b=&y}
        hr := &h4
        h4.b = &a[0]
        test.eq(1, hr.b.*)
    a << 3
    test.eq(3, a.len())

    -- A borrow that is stored through a borrow.
    var r2 &int = &y
    pp := &r2
    pp.* = &z
    test.eq(7, r2.*)

run()

fn run2():
    y := 5
    z := 7
    u := 8
    v := 9

    -- A `scope` parameter stored behind another parameter, also through a call that passes it on.
    var h5 H = H{a=&y, b=&y}
    put(&&h5, &z)
    test.eq(7, h5.b.*)
    o := Outer{v=View{a=&u}}
    o.set(&v)
    test.eq(9, o.v.a.*)
    forward(&&o, &z)
    test.eq(7, o.v.a.*)

    -- Returns from a `scope` parameter.
    h6 := mk(&y)
    test.eq(5, h6.b.*)
    w2 := W{x=9, q=&y}
    test.eq(9, field_of(&w2).*)

run2()

--cytest: pass
