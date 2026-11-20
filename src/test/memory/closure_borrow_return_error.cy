type F = fn() -> int

-- A closure that captures a borrow is an `OpaqueFunc`, a borrow container.
fn mk() -> OpaqueFunc[F]:
    x := 42
    c := &x
    return fn() -> int => c.* + 1

print(mk()())

--cytest: error
--CompileError: Returning a borrow container requires a `scope` modifier.
--
--@MainPath():4:12:
--fn mk() -> OpaqueFunc[F]:
--           ^~~~~~~~~~~~~
--