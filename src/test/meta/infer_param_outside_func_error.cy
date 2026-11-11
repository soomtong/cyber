type A = %x

--cytest: error
--CompileError: `%x` can only be declared in the signature of a function.
--
--@MainPath():1:10:
--type A = %x
--         ^~
--@MainPath():1:1:
--type A = %x
--^~~~~~~~~~~
--
