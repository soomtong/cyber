-- The right side of an assignment that moved its local can not leave the loop: the local of the outer block would be read after the loop.
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
for 0..3 |i|:
    a = maybe(a, i < 1) !else:
        break

--cytest: error
--CompileError: Cannot leave the assignment to `a` here: its right side moved `a`, which is declared outside the block that ends here. Move it to a new variable in a statement before this one.
--
--@MainPath():17:9:
--        break
--        ^~~~~
--