-- The condition of an `else` branch is evaluated conditionally: a branch of an `if` expression in it can not move an
-- outer local either.
type R struct:
    with NoCopy
    id int

fn take(r R) -> int:
    return r.id

fn run(i int, j int):
    a := R{id=1}
    if i == 5:
        pass
    else (if (j == 0) take(a) else 0) == 7:
        pass

run(0, 0)

--cytest: error
--CompileError: Cannot move `a` in the condition of an `else` branch: the condition is evaluated conditionally. Move it inside the branch, or borrow it with `&a`.
--
--@MainPath():14:28:
--    else (if (j == 0) take(a) else 0) == 7:
--                           ^
--