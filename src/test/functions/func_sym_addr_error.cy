fn f(a int) -> int:
    return a
x := *f

--cytest: error
--CompileError: Can not take the address of a function symbol. Assign it to a variable first.
--
--@MainPath():3:7:
--x := *f
--      ^
--
