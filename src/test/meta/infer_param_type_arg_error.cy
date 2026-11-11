a := Array[%x]{}

--cytest: error
--CompileError: `%x` can only be declared in the signature of a function.
--
--@MainPath():1:12:
--a := Array[%x]{}
--           ^~
--
