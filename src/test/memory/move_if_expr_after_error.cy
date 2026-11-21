-- A local that a branch of an `if` expression moved is dead after the expression.
type R struct:
    with NoCopy
    id int

fn take(r R) -> int:
    return r.id

flag := true
a := R{id=1}
n := if (flag) take(a) else 0
print(a.id)

--cytest: error
--CompileError: `a` was moved at 11:21. Borrow it with `&a` or clone it to use it here.
--
--@MainPath():12:7:
--print(a.id)
--      ^
--