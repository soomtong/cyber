print(symbol.a * 2.5)

--cytest: error
--CompileError: Expected `symbol`, found `float`.
--
--@MainPath():1:18:
--print(symbol.a * 2.5)
--                 ^~~
--
