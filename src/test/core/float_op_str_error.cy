f := 2.5
print(f + 'abc')

--cytest: error
--CompileError: Expected `float`, found `str`.
--
--@MainPath():2:11:
--print(f + 'abc')
--          ^~~~~
--
