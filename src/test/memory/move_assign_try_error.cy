-- A failing `!` goes to the `else` block of the `try`, which reads the local that the right side moved.
type R struct:
    with NoCopy
    id int

fn take(r R):
    pass

fn maybe(r R, ok bool) -> !R:
    if !ok:
        return error.Nope
    return R{id=r.id + 10}

fn run() -> int:
    a := R{id=1}
    try:
        a = maybe(a, false)!
    else |err|:
        return a.id
    return a.id
print(run())

--cytest: error
--CompileError: Cannot leave the assignment to `a` here: its right side moved `a`, which is declared outside the block that ends here. Move it to a new variable in a statement before this one.
--
--@MainPath():17:13:
--        a = maybe(a, false)!
--            ^~~~~~~~~~~~~~~~
--