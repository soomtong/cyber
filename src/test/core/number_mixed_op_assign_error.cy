i := 7
f := 2.5
i += f

--cytest: error
--CompileError: Expected type `int`, got `float`.
--
--@MainPath():3:1:
--i += f
--^~~~~~
--
