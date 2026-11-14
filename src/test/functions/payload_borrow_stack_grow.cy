-- A borrow inside the payload of a result or a choice is patched when the stack moves.
use test

fn rec(n int) -> int:
    if n == 0: return 0
    k := 0
    while k < 1:
        k += 1
    return rec(n - 1) + k

type Ref enum:
    case none
    case one &int

fn pick(p &int) -> !&int:
    return p

x := 42
r := pick(&x)
c := Ref.one(&x)
test.eq(rec(20000), 20000)
x = 7
test.eq(r!.*, 7)
switch c:
    case .one |p|:
        test.eq(p.*, 7)
    else:
        test.fail()

-- A fiber stack moves.
fn work(out ^int) -> void:
    y := 5
    rr := pick(&y)
    cc := Ref.one(&y)
    _ = rec(20000)
    y = 6
    q := rr !else &y
    switch cc:
        case .one |p|:
            out.* = q.* + p.*
        else:
            out.* = 0
o := ^int(0)
fb := fiber work(o)
_ = fb.resume()
test.eq(o.*, 12)

-- An `int` of another case keeps its value even when it looks like an address in the stack that moves.
type Slot enum:
    case num int
    case one &int

fn keep_num() -> int:
    y := 5
    addr := as[int] *y
    s := Slot.num(addr)
    _ = rec(20000)
    switch s:
        case .num |n|:
            return n - addr
        else:
            return -1
test.eq(keep_num(), 0)

-- In a fiber whose own stack moves.
fn keep_num_fiber(out ^int) -> void:
    out.* = keep_num()
o2 := ^int(-1)
fb2 := fiber keep_num_fiber(o2)
_ = fb2.resume()
test.eq(o2.*, 0)

--cytest: pass
