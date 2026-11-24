i := 7
print(i < 'abc')

--cytest: error
--CompileError: Expected type `int`, got `str`.
--
--@MainPath():2:11:
--print(i < 'abc')
--          ^~~~~
--
