-- A local that a loop body moved before a `break` is dead after the loop.
type R struct:
    with NoCopy
    id int

fn take(r R):
    pass

a := R{id=1}
for 0..3 |i|:
    if i == 1:
        take(a)
        break
take(a)

--cytest: error
--CompileError: `a` was moved at 12:14. Borrow it with `&a` or clone it to use it here.
--
--@MainPath():14:6:
--take(a)
--     ^
--