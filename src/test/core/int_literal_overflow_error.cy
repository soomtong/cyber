a := 9223372036854775808

--cytest: error
--CompileError: Integer literal does not fit the target type.
--
--@MainPath():1:6:
--a := 9223372036854775808
--     ^~~~~~~~~~~~~~~~~~~
--
