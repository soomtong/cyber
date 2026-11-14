i := 'abc'.zzz('b')

--cytest: error
--CompileError: Can not find the symbol `zzz` in `str`.
--
--@MainPath():1:12:
--i := 'abc'.zzz('b')
--           ^~~
--