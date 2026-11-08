a := 10
opt := ?&int(&a)
lift := ^opt

--cytest: error
--CompileError: Cannot lift the borrow container type `?&int`.
--
--@MainPath():3:9:
--lift := ^opt
--        ^~~~
--
