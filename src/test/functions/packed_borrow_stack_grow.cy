-- Borrows in a struct and a vector are patched when the stack moves. On a 32-bit target (wasm32) a pointer is
-- 4 bytes: two of them share a register, so the second one is the upper half (F-156).
use test

fn rec(n int) -> int:
    if n == 0: return 0
    k := 0
    while k < 1:
        k += 1
    return rec(n - 1) + k

type Two:
    a &int
    b &int

type Three:
    n int
    a &int
    b &int
    c &int

fn check(depth int) -> int:
    x := 1
    y := 2
    t := Two{a=&x, b=&y}
    u := Three{n=0, a=&y, b=&x, c=&y}
    var v [3]&int = [3]&int{&x, &y, &x}
    test.eq(rec(depth), depth)
    x = 10
    y = 20
    return t.a.* + t.b.* + u.a.* + u.b.* + u.c.* + v[0].* + v[1].* + v[2].*

test.eq(check(20000), 120)

-- A fiber stack moves.
fn work(out ^int) -> void:
    out.* = check(20000)

out := ^0
f := fiber work(out)
test.eq(f.resume(), .done)
test.eq(out.*, 120)

-- The halves of a register are pointers in different cases of a choice: the lower half in `one`, the upper half in
-- `mix`. Each half is patched only in its case, so the `i32` of `mix` keeps its value even when it looks like an
-- address in the stack that moves (F-159).
type Mix:
    n i32
    p Ptr[int]

type Half enum:
    case one &int
    case mix Mix

fn halves() -> int:
    y := 5
    -- On a 32-bit target this is the address of `y`.
    n := as[i32] ((as[int] *y) && 0x7fffffff)
    a := Half.one(&y)
    b := Half.mix(Mix{n=n, p=*y})
    _ = rec(20000)
    y = 7
    var res int = 0
    switch a:
        case .one |r|:
            res += r.*
        else:
            res += 1000
    switch b:
        case .mix |m|:
            res += m.p.* * 10
            if m.n != n:
                res += 100
        else:
            res += 1000
    return res
test.eq(halves(), 77)

fn halves_fiber(o ^int) -> void:
    o.* = halves()
out2 := ^0
f2 := fiber halves_fiber(out2)
test.eq(f2.resume(), .done)
test.eq(out2.*, 77)

--cytest: pass
