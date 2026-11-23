type Shape trait:
    generator fn sides() -> int:
        yield 1

--cytest: error
--CompileError: A default method of a trait can not be a generator.
--
--@MainPath():2:5:
--    generator fn sides() -> int:
--    ^~~~~~~~~~~~~~~~~~~~~~~~~~~~
--@MainPath():1:1:
--type Shape trait:
--^~~~~~~~~~~~~~~~~
--
