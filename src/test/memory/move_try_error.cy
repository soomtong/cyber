-- A `try` block can not move a local of an outer block: the `else` block can run after the move.
type R struct:
    with NoCopy
    id int

fn take(r R):
    pass

fn f():
    a := R{id=1}
    try:
        take(a)
    else |err|:
        pass

f()

--cytest: error
--CompileError: Cannot move `a` here: it is declared outside this block. A branch of an `if` or `switch` statement, a `begin:` block and a loop body can move an outer variable, this block can not. Borrow it with `&a`.
--
--@MainPath():12:14:
--        take(a)
--             ^
--