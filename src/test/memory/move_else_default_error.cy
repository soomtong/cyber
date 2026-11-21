-- The default of `?else` is evaluated conditionally: it can not move a local.
type R struct:
    with NoCopy
    id int

fn take(r R) -> int:
    return r.id

var opt ?int = none
a := R{id=1}
n := opt ?else take(a)

--cytest: error
--CompileError: Cannot move `a` inside a `?else` expression: a part of the expression is evaluated conditionally. Borrow it with `&a`, or move it to a variable in a statement before this one.
--
--@MainPath():11:21:
--n := opt ?else take(a)
--                    ^
--