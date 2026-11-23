fn call(f fn(%T) -> int) -> int:
    return 1

fn one(x int) -> int:
    return 1

print(call(one))

--cytest: error
--CompileError: Can not infer the template parameter `T` from the argument for `f`. Declare it as its own parameter (`%T type`) and pass the type in the call.
--
--@MainPath():7:12:
--print(call(one))
--           ^~~
--