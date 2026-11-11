n := 1
f := fiber:
    print(n)

--cytest: error
--CompileError: Can only capture variables declared with the reference types `^T` or `&T`.
--
--@MainPath():3:11:
--    print(n)
--          ^
--
