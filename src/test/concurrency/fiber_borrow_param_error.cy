fn bump(n &int):
    n.* += 1

n := 1
f := fiber bump(&n)

--cytest: error
--CompileError: Cannot borrow a stack value across fibers. The parameter type is `&int`. Use `^T`.
--
--@MainPath():5:6:
--f := fiber bump(&n)
--     ^~~~~~~~~~~~~~
--
