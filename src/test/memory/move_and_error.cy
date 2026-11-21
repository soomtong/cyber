-- The right side of `and` is evaluated conditionally: it can not move a local. The message names the expression,
-- not an outer block.
type R struct:
    with NoCopy
    id int

fn take(r R) -> int:
    return r.id

flag := true
a := R{id=1}
ok := flag and take(a) > 0

--cytest: error
--CompileError: Cannot move `a` inside an `and` expression: a part of the expression is evaluated conditionally. Borrow it with `&a`, or move it to a variable in a statement before this one.
--
--@MainPath():12:21:
--ok := flag and take(a) > 0
--                    ^
--