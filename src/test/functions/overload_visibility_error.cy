fn f(a int) -> int:
    return a

-fn f(a float) -> int:
    return 1

--cytest: error
--CompileError: Overloads of `f` must have the same visibility.
--
--@MainPath():4:1:
---fn f(a float) -> int:
--^~~~~~~~~~~~~~~~~~~~~~
--
