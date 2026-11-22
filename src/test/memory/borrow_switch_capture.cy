use test

-- A `switch` capture borrows from what the control borrows, until the case ends.

type Ref enum:
    case none
    case one &int

type Slot enum:
    case num int
    case one &int

fn pick(scope p &int) -> scope Ref:
    return Ref.one(p)

fn run():
    y := 5
    x := 7
    c := Ref.one(&y)

    s := switch c:
        case .one |p| => p
        else => &x
    test.eq(5, s.*)

    w := switch c:
        case .none => &x
        case .one |p| => p
    test.eq(5, w.*)

    u := switch pick(&y):
        case .one |p| => p
        else => &x
    test.eq(5, u.*)

    sl := Slot.num(3)
    t := switch sl:
        case .num |&n| => n
        else => &x
    test.eq(3, t.*)

    -- A capture can be assigned to a borrow that its owner outlives.
    var r &int = &x
    switch c:
        case .one |p|:
            r = p
        else:
            pass
    test.eq(5, r.*)

run()

--cytest: pass
