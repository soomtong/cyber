use test

-- A borrow local without a destructor ends after the last statement of its block that names it.
-- See `docs/decisions/project_borrow_model.md` "비어휘적 수명".

type Holder:
    r &&Array[int]

type View:
    p &int

fn run():
    a := Array[int]{1, 2, 3}

    -- An element borrow, then a resize.
    elem := &a[2]
    test.eq(3, elem.*)
    a << 4
    test.eq(4, a.len())

    -- An exclusive borrow, then a shared borrow.
    ex := &&a
    ex << 5
    s := &a[0]
    test.eq(1, s.*)
    a << 6
    test.eq(6, a.len())

    -- A borrow that is never named again.
    _p := &a[1]
    a << 7

    -- The last statement that names the borrow is a loop.
    e := &a[0]
    sum := 0
    for 0..3 |i|:
        sum += e.*
    a << 8
    test.eq(3, sum)

    -- A name in a range.
    n := &a[1]
    count := 0
    for 0..n.* |i|:
        count += 1
    a << 0
    _ = a.pop()
    test.eq(2, count)

    -- A name in a string interpolation.
    t := &a[1]
    test.eq('2', '%{t.*}')
    a << 9

    -- A member of the same name (`a.len`) does not name the local `len`.
    len := &a[0]
    test.eq(1, len.*)
    a << 10
    test.eq(10, a.len())

    -- A borrow container.
    h := Holder{r=&&a}
    h.r << 11
    test.eq(11, a.len())

    -- A struct of shared borrows.
    y := 5
    w := View{p=&y}
    test.eq(5, w.p.*)
    q := &&y
    q.* = 6
    test.eq(6, y)

    -- In an inner block.
    if true:
        u := &a[0]
        test.eq(1, u.*)
        a << 12
    test.eq(12, a.len())

run()

--cytest: pass
