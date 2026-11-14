use test

-- F-136. A pinned closure keeps its captured borrows (`&T`) on the heap, out of reach of the frame pointer
-- layouts. When the stack moved, a borrow of a stack value still pointed into the freed stack.

fn rec(n int) -> int:
    if n == 0: return 0
    k := 0
    while k < 1:
        k += 1
    return rec(n - 1) + k

-- The stack moves between the capture and the call.
x := 42
c := &x
f := fn() -> int:
    return c.* + 1
test.eq(f(), 43)
test.eq(rec(20000), 20000)
x = 7
test.eq(f(), 8)

-- The stack moves inside the comparator of `sort`.
counts := Map[str, int]{app=7, db=8, web=23}
names := counts.keys()
cs := &counts
names.sort(|a, b| rec(3000) > 0 and cs[a] > cs[b])
test.eq(names[0], 'web')
test.eq(names[2], 'app')

-- A fiber stack moves.
fn work(out ^int) -> void:
    y := 42
    cy := &y
    g := fn() -> int:
        return cy.* + 1
    _ = rec(20000)
    y = 9
    out.* = g()

out := ^0
fb := fiber work(out)
_ = fb.resume()
test.eq(out.*, 10)

--cytest: pass
