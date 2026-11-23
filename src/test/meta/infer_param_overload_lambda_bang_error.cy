-- When no overload takes the lambda, the error is the one of the overload that came closest, at the `!` that
-- its result type can not pass on.
fn conv(x str, f fn(str) -> int) -> str:
    return 'i'
fn conv(x str, f fn(str) -> float) -> str:
    return 'f'

print(conv('12', |x| int.parse(x)!))

--cytest: error
--CompileError: Expected a `!T` or `error` return type for `!`. The lambda returns `int`, so `!` can not pass the error on. Declare it `-> !int`, or handle the error here with `!else` or `try`.
--
--@MainPath():8:22:
--print(conv('12', |x| int.parse(x)!))
--                     ^~~~~~~~~~~~~
--
