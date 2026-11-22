use test

-- A borrow that a `switch` expression, `?else`, `!else` or `!` gives borrows from its owners until its last use.
-- See `docs/decisions/project_borrow_model.md` "갈래가 주는 빌림".

fn first(scope a &Array[int]) -> scope !&int:
    return &a[0]

fn none_of(scope a &Array[int]) -> scope ?&int:
    return none

fn run() -> !void:
    a := Array[int]{1, 2, 3}
    y := 7
    x := 2

    s := switch x:
        case 1 => &a[0]
        case 2 => &a[1]
        else => &y
    test.eq(2, s.*)
    a << 4

    var o ?&int = none
    d := o ?else &a[2]
    test.eq(3, d.*)
    a << 5

    n := none_of(&a) ?else &y
    test.eq(7, n.*)
    a << 6

    r := first(&a) !else &y
    test.eq(1, r.*)
    a << 7

    u := first(&a)!
    test.eq(1, u.*)
    a << 8

    held := first(&a)
    test.eq(1, (held !else &y).*)
    a << 9

    e := if (x == 2) &y else &a[0]
    test.eq(7, e.*)
    a << 10

    m := switch x:
        case 2 => &&a
        else => &&a
    m << 11
    a << 12
    test.eq(12, a.len())

run()!

--cytest: pass
