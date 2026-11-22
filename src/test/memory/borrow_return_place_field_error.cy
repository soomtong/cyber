-- A `scope` function can not return a borrow of a place in one of its locals, also when the local borrows from the
-- `scope` parameter.
type W:
    x int
    q &int

fn mk(scope p &int) -> scope &int:
    w := W{x=42, q=p}
    return &w.x

y := 5
r := mk(&y)
print(r.*)

--cytest: error
--CompileError: Expected to return a borrow from the same scope as `p`.
--
--@MainPath():9:5:
--    return &w.x
--    ^~~~~~~~~~~
--
