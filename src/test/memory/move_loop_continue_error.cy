-- A loop body that moves a local of an outer block can not go on to the next iteration.
type R struct:
    with NoCopy
    id int

fn take(r R):
    pass

a := R{id=1}
for 0..3 |i|:
    if i == 1:
        take(a)
        continue

--cytest: error
--CompileError: Cannot move `a` here: it is declared outside the loop, and the next iteration reads it. A loop body can move it where it then leaves the loop with `break` or `return`, or gives it a value again. Borrow it with `&a`.
--
--@MainPath():12:14:
--        take(a)
--             ^
--