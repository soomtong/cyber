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

fn sum(a R, b int) -> int:
    return a.id + b

fn sum(a R, b str) -> int:
    return a.id + b.len()

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

    -- An overloaded function: the first candidate does not match, and the second one moves the local or the member.
    e := R{id=6}
    test.eq(8, sum(e, 'ab'))
    box2 := Box{r=R{id=7}, n=8}
    test.eq(10, sum(box2.r, 'abc'))
    test.eq(8, box2.n)

run()

--cytest: pass
