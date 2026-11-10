type P:
    a int
    a int

--cytest: error
--CompileError: `a` has already been declared as a `field`
--
--@MainPath():3:5:
--    a int
--    ^~~~~
--@MainPath():1:1:
--type P:
--^~~~~~~
--
