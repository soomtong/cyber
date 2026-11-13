a := 123
b := fn():
    return a

--cytest: error
--CompileError: Can only capture variables declared with the reference types `^T` or `&T`. Declare it with `^T`, or borrow it before the lambda (`b := &a`) and use `b` in the lambda.
--
--@MainPath():3:12:
--    return a
--           ^
--