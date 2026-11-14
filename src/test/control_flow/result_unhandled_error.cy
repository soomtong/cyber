fn f() -> !void:
    return
f()

--cytest: error
--CompileError: Expected to handle the error case for `!void`. Add `!` after the call to unwrap it, or handle the error with `!else` or `try`.
--
--@MainPath():3:1:
--f()
--^~~
--