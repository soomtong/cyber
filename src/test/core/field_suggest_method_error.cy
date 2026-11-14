s := 'ab'
print(s.length)

--cytest: error
--CompileError: Field `length` does not exist in `str`. Did you mean the method `len()`?
--
--@MainPath():2:9:
--print(s.length)
--        ^~~~~~
--