use test

-- An `if` or `while` unwrap capture borrows from what the option borrows, until the branch ends.

type H:
    o ?&int

fn pick(scope p &int) -> scope ?&int:
    return p

fn run():
    y := 5
    x := 7
    var r &int = &x
    o := ?&int(&y)
    if o |q|:
        r = q
    test.eq(5, r.*)

    r = &x
    var w ?&int = &y
    while w |q|:
        r = q
        w = none
    test.eq(5, r.*)

    r = &x
    if pick(&y) |q|:
        r = q
    test.eq(5, r.*)

    r = &x
    h := H{o=&y}
    if h.o |q|:
        r = q
    test.eq(5, r.*)

    -- A capture of a value is a copy that ends with the branch.
    n := ?int(3)
    if n |q|:
        test.eq(3, q)

run()

--cytest: pass
