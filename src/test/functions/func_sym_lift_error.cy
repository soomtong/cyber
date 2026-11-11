fn f(a int) -> int:
    return a
x := ^f

--cytest: error
--CompileError: A function symbol can not be lifted. Assign it to a variable first.
--
--@MainPath():3:7:
--x := ^f
--      ^
--
