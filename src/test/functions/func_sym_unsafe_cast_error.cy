fn f(a int) -> int:
    return a
x := @unsafeCast(f, 1)

--cytest: error
--CompileError: The type `funcsym(int) -> int` has no size.
--
--@MainPath():3:6:
--x := @unsafeCast(f, 1)
--     ^~~~~~~~~~~~~~~~~
--
