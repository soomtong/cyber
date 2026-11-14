xs := {1, 2}
xs[0] = 'ab'

--cytest: error
--CompileError: An element of `[]int` must be `int`, got `str`.
--
--@MainPath():2:9:
--xs[0] = 'ab'
--        ^~~~
--
