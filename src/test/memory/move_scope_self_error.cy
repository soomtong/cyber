-- The `Scope` of a `scope` block does not move: the block joins its fibers at its end.
fn take(s Scope):
    pass

fn f() -> !void:
    scope |s|:
        take(move s)

f()!

--cytest: error
--CompileError: Cannot move `s`: it is the scope of a `scope` block, which joins its fibers at the end of the block. Borrow it with `&&s`.
--
--@MainPath():7:19:
--        take(move s)
--                  ^
--