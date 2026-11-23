-- No argument before the lambda binds `T`, so the type of `x` is not known.
fn call(f fn(%T) -> int) -> int:
    return 1

print(call(|x| 1))

--cytest: error
--CompileError: Can not infer the template parameter `T` from the lambda for `f`. The type of the lambda parameter `x` must be known from the arguments before the lambda. Declare the types of the lambda (`fn(x T) -> U: ...`), or declare `%T type` as its own parameter and pass the type in the call.
--
--@MainPath():5:12:
--print(call(|x| 1))
--           ^~~~~
--