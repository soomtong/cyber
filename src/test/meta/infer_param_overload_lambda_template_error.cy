-- When no overload takes the lambda, the error is the one of the overload that came closest, also when that
-- overload infers template parameters.
fn conv(x %T, f fn(T) -> str) -> str:
    return f(x)
fn conv(x float, f fn(float) -> float) -> str:
    return 'f'

print(conv(1, |x| x > 0))

--cytest: error
--CompileError: Expected type `str`, got `bool`.
--
--@MainPath():8:19:
--print(conv(1, |x| x > 0))
--                  ^~~~~
--
