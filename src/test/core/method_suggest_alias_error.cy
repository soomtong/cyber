i := 'abc'.find('b')

--cytest: error
--CompileError: Can not find the symbol `find` in `str`. Did you mean `index`?
--
--@MainPath():1:12:
--i := 'abc'.find('b')
--           ^~~~
--