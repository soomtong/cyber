-- A loop body that moves a local of an outer block can not reach its end: the next iteration reads the local.
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
--CompileError: Cannot move `a` here: it is declared outside the loop, and the next iteration reads it. A loop body can move it where it then leaves the loop with `break` or `return`, or gives it a value again. Borrow it with `&a`.
--
--@MainPath():12:14:
--        take(a)
--             ^
--