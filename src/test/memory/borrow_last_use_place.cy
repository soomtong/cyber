use test

-- A container that holds a borrow of a place in another container keeps only that container from ending early, and a
-- copy that is read through a borrow of a container that borrows only its owners points into those owners.
-- See `docs/decisions/project_borrow_model.md` "자리 대상 지역 목록".

type W:
    x int
    q &int

type H:
    a &int
    b &int

fn get(scope p &int) -> scope &int:
    h := H{a=p, b=p}
    hr := &h
    r := hr.b
    return r

fn get2(scope p &int) -> scope &int:
    var h H = H{a=p, b=p}
    hr := &h
    var r &int = p
    r = hr.b
    return r

fn run():
    y := 5
    z := 7
    w := W{x=42, q=&z}

    -- `g` points into `w` only. `h` ends after its last use while `g` lives.
    g := H{a=&y, b=&w.x}
    a := Array[int]{1, 2}
    h := H{a=&y, b=&a[0]}
    test.eq(1, h.b.*)
    a << 3
    test.eq(3, a.len())

    -- A copy of `g` points into `w` too.
    g2 := g
    h2 := H{a=&y, b=&a[1]}
    test.eq(2, h2.b.*)
    a << 4
    test.eq(4, a.len())
    test.eq(42, g.b.*)
    test.eq(42, g2.b.*)

    test.eq(5, get(&y).*)
    test.eq(5, get2(&y).*)

run()

--cytest: pass
