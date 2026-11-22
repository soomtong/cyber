use test

-- A borrow from one of several owners can be stored in a field or an element, or passed as an argument, while no
-- owner is changed.

type Holder:
    r &int

fn sum(r &int, b &Array[int]) -> int:
    return r.* + b.len()

fn grow(b &&Array[int]) -> int:
    b << 0
    return b.len()

fn read_after_grow(r &int, b &&Array[int]) -> int:
    b << 0
    return r.*

fn run(k int):
    a := Array[int]{1, 2, 3}
    y := 7
    z := 8

    h := Holder{r=&y}
    h.r = if (k == 2) &y else &a[0]
    test.eq(1, h.r.*)
    -- `h` is not used after this, so `a` can grow.
    a << 4

    test.eq(4 + 1, sum(if (k == 2) &y else &a[0], &a))
    test.eq(5, grow(&&a))
    -- Neither owner is the one that the other argument borrows exclusively.
    test.eq(8, read_after_grow(if (k == 2) &y else &z, &&a))

    rs := [1]&int{&y}
    rs[0] = switch k:
        case 2 => &y
        else => &a[1]
    test.eq(2, rs[0].*)

run(1)

--cytest: pass
