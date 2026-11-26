d := 7
print('0' + d)

--cytest: error
--CompileError: Can not apply `+` to `str` and `int`. To join them, write `'0%{d}'`.
--
--@MainPath():2:13:
--print('0' + d)
--            ^
--