-- The condition of a `while` loop runs before every iteration: it can not move a local that is declared outside the
-- loop, also when the body always leaves the loop.
type R struct:
    with NoCopy
    id int

fn take(r R) -> int:
    return r.id

a := R{id=1}
while take(a) == 2:
    break

--cytest: error
--CompileError: Cannot move `a` in the condition of a `while` loop: it is declared outside the loop, and the condition is evaluated before every iteration. Borrow it with `&a`, or write `while:` and move it in the body where the body then leaves the loop with `break` or `return`.
--
--@MainPath():11:12:
--while take(a) == 2:
--           ^
--