i := '3'
if i > 0:
    print(i)

--cytest: error
--CompileError: Can not compare `str` with `int`. Convert one side: `int(i)` or `'%{0}'`.
--
--@MainPath():2:8:
--if i > 0:
--       ^
--