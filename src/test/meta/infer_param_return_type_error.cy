fn f(x int) -> %U:
    return x

--cytest: error
--CompileError: `%U` can not be declared in a return type. Declare it in a parameter (`%U type`) instead.
--
--@MainPath():1:16:
--fn f(x int) -> %U:
--               ^~
--
