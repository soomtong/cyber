s := ' a '
t := s.trimStart()

--cytest: error
--CompileError: Can not find the symbol `trimStart` in `str`. Did you mean `trimLeft`?
--
--@MainPath():2:8:
--t := s.trimStart()
--       ^~~~~~~~~
--
