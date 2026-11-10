type A struct:
    x int

a := A{1 = 2}

--cytest: error
--CompileError: Expected field name.
--
--@MainPath():4:8:
--a := A{1 = 2}
--       ^
--
