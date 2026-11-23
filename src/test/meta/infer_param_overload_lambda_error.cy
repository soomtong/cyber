-- When no overload takes the lambda, the error is the one of the overload that came closest,
-- at the body of the lambda.
fn conv(x int, f fn(int) -> str) -> str:
    return f(x)
fn conv(x str, f fn(int) -> float) -> str:
    return x
fn conv(x int, f fn(int) -> bool) -> str:
    return 'b'

print(conv(1, |x| x + 1))

--cytest: error
--CompileError: Expected type `str`, got `int`.
--
--@MainPath():10:19:
--print(conv(1, |x| x + 1))
--                  ^~~~~
--
