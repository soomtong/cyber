r := 3..>0

--cytest: error
--CompileError: A decreasing range is only allowed in a `for` loop.
--
--@MainPath():1:6:
--r := 3..>0
--     ^~~~~
--