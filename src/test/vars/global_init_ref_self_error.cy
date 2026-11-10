global a int = a + 1

--cytest: error
--CompileError: The initializer of `a` accesses `a` before it is initialized.
--
--@MainPath():1:16:
--global a int = a + 1
--               ^~~~~
--
