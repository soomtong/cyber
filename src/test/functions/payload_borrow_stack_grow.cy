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

--cytest: pass
