n := 1
f := fiber:
    print(n)

--cytest: error
--CompileError: Can only capture variables declared with the reference types `^T` or `&T`. Declare it with `^T`, or borrow it before the lambda (`b := &n`) and use `b` in the lambda.
--
--@MainPath():3:11:
--    print(n)
--          ^
--
