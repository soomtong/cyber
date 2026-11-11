generator fn countdown(n int) -> int:
    yield n

f := fiber countdown(3)

--cytest: error
--CompileError: A generator cannot be a fiber entry.
--
--@MainPath():4:6:
--f := fiber countdown(3)
--     ^~~~~~~~~~~~~~~~~~
--
