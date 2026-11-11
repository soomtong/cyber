fn one() -> int:
    return 1

f := fiber one()

--cytest: error
--CompileError: A fiber entry function must return `void`.
--
--@MainPath():4:6:
--f := fiber one()
--     ^~~~~~~~~~~
--
