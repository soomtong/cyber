use test

type F = fn() -> int

-- A closure that borrows a parameter can be returned through a `scope` return.
fn mk(scope p &int) -> scope OpaqueFunc[F]:
    return fn() -> int => p.* + 1

x := 42
f := mk(&x)
test.eq(43, f())

-- Within the scope of the borrowed local.
y := 1
c := &y
g := fn() -> int:
    return c.* + 1
h := g
test.eq(2, h())
begin:
    z := 10
    cz := &z
    k := fn() -> int:
        return cz.* + c.*
    test.eq(11, k())

--cytest: pass