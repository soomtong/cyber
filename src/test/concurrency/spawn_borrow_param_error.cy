fn f(a &int) -> int:
    return a.*

n := 1
x := spawn f(&n)

--cytest: error
--CompileError: Cannot borrow a value across threads. The parameter type is `&int`. Take the value instead.
--
--@MainPath():5:6:
--x := spawn f(&n)
--     ^~~~~~~~~~~
--