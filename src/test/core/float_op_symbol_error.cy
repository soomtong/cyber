print(2.5 * symbol.a)

--cytest: error
--CompileError: Expected `float`, found `symbol`.
--
--@MainPath():1:13:
--print(2.5 * symbol.a)
--            ^~~~~~~~
--
