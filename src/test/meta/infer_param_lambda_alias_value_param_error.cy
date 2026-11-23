-- The value parameter of the alias is in the type of the lambda parameter, which is not known.
type InFn[const N int, T Any] = fn([N]T) -> T

fn pf(x %T, f InFn[%N, T]) -> T:
    return x

print(pf(4, |a| a[0]))

--cytest: error
--CompileError: Can not infer the template parameter `N` from the lambda for `f`. The type of the lambda parameter `a` must be known from the arguments before the lambda. Declare the types of the lambda (`fn(x T) -> U: ...`), or declare `%N type` as its own parameter and pass the type in the call.
--
--@MainPath():7:13:
--print(pf(4, |a| a[0]))
--            ^~~~~~~~
--