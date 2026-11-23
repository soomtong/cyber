type P:
    x int

a := ?P{x=1}

--cytest: error
--CompileError: Can not infer initializer type `?P`.
--
--@MainPath():4:8:
--a := ?P{x=1}
--       ^~~~~
--
