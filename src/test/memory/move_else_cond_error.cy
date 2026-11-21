-- The condition of an `else` branch is evaluated only when the conditions before it are false: it can not move a
-- local. The first condition of the `if` statement can.
type R struct:
    with NoCopy
    id int

fn take(r R) -> int:
    return r.id

flag := false
a := R{id=1}
if flag:
    pass
else take(a) > 0:
    pass

--cytest: error
--CompileError: Cannot move `a` in the condition of an `else` branch: the condition is evaluated conditionally. Move it inside the branch, or borrow it with `&a`.
--
--@MainPath():14:11:
--else take(a) > 0:
--          ^
--