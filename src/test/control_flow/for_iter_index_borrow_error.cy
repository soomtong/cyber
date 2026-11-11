a := []int{1, 2}
for a |&i, e|:
    pass

--cytest: error
--CompileError: Expected a variable name for the index.
--
--@MainPath():2:8:
--for a |&i, e|:
--       ^~
--
