-- The function type declares `T` in a parameter and uses it again. The lambda is typed before `T` is bound.
fn twice(f fn(%T) -> T, x T) -> T:
    return f(f(x))

print(twice(|x| x * 2, 3))

--cytest: error
--CompileError: Can not infer the template parameter `T` from the lambda for `f`. The type of the lambda parameter `x` must be known from the arguments before the lambda. Declare the types of the lambda (`fn(x T) -> U: ...`), or declare `%T type` as its own parameter and pass the type in the call.
--
--@MainPath():5:13:
--print(twice(|x| x * 2, 3))
--            ^~~~~~~~~
--