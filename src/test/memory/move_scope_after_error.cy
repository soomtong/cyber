-- A local that the body of a `scope` block moved is dead after the block.
type R struct:
    with NoCopy
    id int

fn take(r R):
    pass

fn f() -> !void:
    a := R{id=1}
    scope |s|:
        take(a)
    take(a)

f()!

--cytest: error
--CompileError: `a` was moved at 12:14. Borrow it with `&a` or clone it to use it here.
--
--@MainPath():13:10:
--    take(a)
--         ^
--