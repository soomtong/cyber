foo = 1

--cytest: error
--CompileError: Undeclared variable `foo`. To declare a new variable, write `foo := ...`.
--
--@MainPath():1:1:
--foo = 1
--^~~
--