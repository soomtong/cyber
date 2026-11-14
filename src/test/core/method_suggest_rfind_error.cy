s := 'a/b'
print(s.rfind('/'))

--cytest: error
--CompileError: Can not find the symbol `rfind` in `str`. Did you mean `lastIndexOf`?
--
--@MainPath():2:9:
--print(s.rfind('/'))
--        ^~~~~
--