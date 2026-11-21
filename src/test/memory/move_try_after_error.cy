-- A local that the body of a `try` statement moved before a failing `!` is dead in the `else` block.
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
    try:
        take(a)
        _ = may(true)!
    else |err|:
        print(a.id)

f()

--cytest: error
--CompileError: `a` was moved at 17:14. Borrow it with `&a` or clone it to use it here.
--
--@MainPath():20:15:
--        print(a.id)
--              ^
--