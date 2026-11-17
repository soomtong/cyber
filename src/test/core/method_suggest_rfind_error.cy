s := 'a/b'
print(s.rfind('/'))

--cytest: error
--CompileError: Can not find the symbol `rfind` in `str`. Did you mean `last_index`?
--
--@MainPath():2:9:
--print(s.rfind('/'))
--        ^~~~~
--