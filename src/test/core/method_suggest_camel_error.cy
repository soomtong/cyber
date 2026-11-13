ok := 'abc'.startsWith('a')

--cytest: error
--CompileError: Can not find the symbol `startsWith` in `str`. Did you mean `starts_with`?
--
--@MainPath():1:13:
--ok := 'abc'.startsWith('a')
--            ^~~~~~~~~~
--