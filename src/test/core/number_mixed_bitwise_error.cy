i := 7
f := 2.5
print(i && f)

--cytest: error
--CompileError: Expected `int`, found `float`.
--
--@MainPath():3:12:
--print(i && f)
--           ^
--
