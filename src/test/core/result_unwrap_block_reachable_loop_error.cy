fn f(n int) -> !int:
    return error.Bad

fn g() -> int:
    for 0..3 |i|:
        v := f(i) !else |err|:
            print(err)
        print(v)
    return 0

--cytest: error
--CompileError: An `!else` block must not reach its end. End it with `return`, `panic(...)`, `break` or `continue`.
--
--@MainPath():6:14:
--        v := f(i) !else |err|:
--             ^~~~~~~~~~~~~~~~~
--
