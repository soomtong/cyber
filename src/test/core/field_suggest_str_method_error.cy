s := 'abc'
n := s.len

--cytest: error
--CompileError: Type `str` does not have a field named `len`. Did you mean the method `len()`?
--
--@MainPath():2:8:
--n := s.len
--       ^~~
--