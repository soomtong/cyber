-- A branch of an `if` expression is evaluated conditionally: it can not move a local.
type R struct:
    with NoCopy
    id int

fn take(r R) -> int:
    return r.id

flag := true
a := R{id=1}
n := if (flag) take(a) else 0

--cytest: error
--CompileError: Cannot move `a` inside an `if` expression: a part of the expression is evaluated conditionally. Borrow it with `&a`, or move it to a variable in a statement before this one.
--
--@MainPath():11:21:
--n := if (flag) take(a) else 0
--                    ^
--