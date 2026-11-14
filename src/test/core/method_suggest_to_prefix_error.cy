s := 'a'.to_upper()

--cytest: error
--CompileError: Can not find the symbol `to_upper` in `str`. Did you mean `upper`?
--
--@MainPath():1:10:
--s := 'a'.to_upper()
--         ^~~~~~~~
--