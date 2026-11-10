type A struct:
    x int
    y int

a := A{x = 2, 3}

--cytest: error
--CompileError: Expected key value pair.
--
--@MainPath():5:15:
--a := A{x = 2, 3}
--              ^
--
