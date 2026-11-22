use test

-- A vector of borrows and a span of it can be iterated. A capture borrows what the vector borrows.

fn run():
    y := 5
    x := 7
    xs := [2]&int{&y, &x}
    var sum int = 0
    for xs |p|:
        sum += p.*
    test.eq(12, sum)
    for xs[1..] |p|:
        sum += p.*
    test.eq(19, sum)

    var r &int = &x
    for xs[..1] |p|:
        r = p
    test.eq(5, r.*)

    -- The vector can end before the capture that is stored.
    r = &x
    if true:
        ys := [1]&int{&y}
        for ys |p|:
            r = p
    test.eq(5, r.*)

    -- A vector of values is iterated as before.
    vs := [3]int{1, 2, 3}
    sum = 0
    for vs |v|:
        sum += v
    for vs[1..] |v|:
        sum += v
    test.eq(11, sum)

run()

--cytest: pass
