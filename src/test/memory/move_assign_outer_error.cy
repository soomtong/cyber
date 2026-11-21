-- An assignment in a loop body or a branch does not give a moved local of an outer block a value: the paths would differ.
type R struct:
    with NoCopy
    id int

fn take(r R):
    pass

fn maybe(r R, ok bool) -> !R:
    if !ok:
        return error.Nope
    return R{id=r.id + 10}

a := R{id=1}
take(a)
for 0..2:
    a = R{id=2}

--cytest: error
--CompileError: Cannot assign to `a` here: it was moved at 15:6 and it is declared in an outer block. Assign to it in the block that declares it, or declare a new variable.
--
--@MainPath():17:5:
--    a = R{id=2}
--    ^
--