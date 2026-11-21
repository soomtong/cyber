-- The `else` block of a `try` statement in a loop goes on to the next iteration after the body moved an outer local.
type R struct:
    with NoCopy
    id int

fn take(r R):
    pass

fn may(ok bool) -> !int:
    if !ok:
        return error.Bad
    return 1

fn f():
    a := R{id=1}
    for 0..3 |i|:
        try:
            take(a)
            _ = may(i > 0)!
            break
        else:
            continue

f()

--cytest: error
--CompileError: Cannot move `a` here: it is declared outside the loop, and the next iteration reads it. A loop body can move it where it then leaves the loop with `break` or `return`, or gives it a value again. Borrow it with `&a`.
--
--@MainPath():18:18:
--            take(a)
--                 ^
--