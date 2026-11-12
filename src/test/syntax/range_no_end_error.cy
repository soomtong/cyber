r := 1..

--cytest: error
--CompileError: Expected range end. A range without an end is only allowed as a slice index.
--
--@MainPath():1:6:
--r := 1..
--     ^~~
--