i := 'abc'.rfind('b')

--cytest: error
--CompileError: Can not find the symbol `rfind` in `str`.
--
--@MainPath():1:12:
--i := 'abc'.rfind('b')
--           ^~~~~
--