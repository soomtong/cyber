a := 1
b := a ?else:
    return

--cytest: error
--CompileError: Expected type instance of `Option`, found `int`. This value is `int`, not an option. Remove the `?else` block.
--
--@MainPath():2:6:
--b := a ?else:
--     ^
--