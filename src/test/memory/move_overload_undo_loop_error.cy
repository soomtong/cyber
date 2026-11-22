-- An overload candidate that does not match takes back the moves of its arguments only: the move of `y` that the
-- loop body made before the call stays, after the `if` expression in the argument joined its branches.
type R struct:
    with NoCopy
    id int

fn take(r R):
    pass

fn take1(r R) -> int:
    return 1

fn f(a int, b str) -> int:
    return 1

fn f(a int, b int) -> int:
    return 2

y := R{id=1}
for 0..3 |i|:
    take(y)
    x := R{id=10 + i}
    k := f(if (i == 0) take1(x) else 0, 5)

--cytest: error
--CompileError: Cannot move `y` here: it is declared outside the loop, and the next iteration reads it. A loop body can move it where it then leaves the loop with `break` or `return`, or gives it a value again. Borrow it with `&y`.
--
--@MainPath():21:10:
--    take(y)
--         ^
--