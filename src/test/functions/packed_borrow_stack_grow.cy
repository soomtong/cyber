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

--cytest: pass
