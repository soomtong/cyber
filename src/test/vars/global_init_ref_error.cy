global b int = a + 1
global a int = 123

--cytest: error
--CompileError: The initializer of `b` accesses the global `a`. `a` is initialized after `b`.
--
--@MainPath():1:16:
--global b int = a + 1
--               ^~~~~
--
