var g f32 = 1.5
f := 2.5
g += f

--cytest: error
--CompileError: Expected type `f32`, got `float`.
--
--@MainPath():3:1:
--g += f
--^~~~~~
--
