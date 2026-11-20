type F = fn() -> int

fn one() -> int:
    return 1

var f OpaqueFunc[F] = one
begin:
    y := 42
    c := &y
    f = fn() -> int => c.* + 1
print(f())

--cytest: error
--CompileError: `f` can not outlive `y`.
--
--@MainPath():10:14:
--    f = fn() -> int => c.* + 1
--             ^~~~~~~~~~~~~~~~~
--