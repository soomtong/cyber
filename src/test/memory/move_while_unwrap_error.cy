-- The option expression of `while opt |v|:` runs before every iteration: it can not move a local that is declared
-- outside the loop.
type R struct:
    with NoCopy
    id int

fn opt(r R) -> ?int:
    return r.id

fn run() -> int:
    a := R{id=1}
    while opt(a) |v|:
        return v
    return 0

_ = run()

--cytest: error
--CompileError: Cannot move `a` in the condition of a `while` loop: it is declared outside the loop, and the condition is evaluated before every iteration. Borrow it with `&a`, or write `while:` and move it in the body where the body then leaves the loop with `break` or `return`.
--
--@MainPath():12:15:
--    while opt(a) |v|:
--              ^
--