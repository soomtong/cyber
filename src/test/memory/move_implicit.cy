use test

-- A `NoCopy` value that would be copied moves when it is read from a local or a member path of one.
-- See `docs/decisions/project_last_use.md`.

type R struct:
    with NoCopy
    id int

type Box:
    r R
    n int

fn take(r R) -> int:
    return r.id

fn run():
    -- An argument.
    a := R{id=1}
    test.eq(1, take(a))

    -- An initializer.
    b := R{id=2}
    c := b
    test.eq(2, c.id)

    -- A field of a literal, then a member path.
    box := Box{r=c, n=3}
    test.eq(2, take(box.r))
    test.eq(3, box.n)

    -- An element of a literal.
    d := R{id=4}
    arr := Array[R]{d}
    test.eq(4, arr[0].id)

    -- A copyable value is still copied.
    n := 5
    m := n
    test.eq(10, n + m)

run()

--cytest: pass
