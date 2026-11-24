f := 2.5
print(f * true)

--cytest: error
--CompileError: Expected `float`, found `bool`.
--
--@MainPath():2:11:
--print(f * true)
--          ^~~~
--
