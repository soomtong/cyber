-- A loop body can not move a local of an outer block: the next iteration reads it.
type R struct:
    with NoCopy
    id int

fn take(r R):
    pass

a := R{id=1}
for 0..2 |i|:
    if i == 1:
        take(a)

--cytest: error
--CompileError: Cannot move `a` here: it is declared in an outer block. A branch of an `if` statement can move it, a loop body can not (the next iteration reads it). Borrow it with `&a`.
--
--@MainPath():12:14:
--        take(a)
--             ^
--