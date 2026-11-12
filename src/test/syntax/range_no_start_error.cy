r := ..3

--cytest: error
--CompileError: Expected range start. A range without a start is only allowed as a slice index.
--
--@MainPath():1:6:
--r := ..3
--     ^~~
--