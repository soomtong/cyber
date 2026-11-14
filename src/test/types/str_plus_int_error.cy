s := 'a'
print(s + 1)

--cytest: error
--CompileError: Can not apply `+` to `str` and `int`. To join them, write `'%{s}%{1}'`.
--
--@MainPath():2:11:
--print(s + 1)
--          ^
--