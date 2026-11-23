-- When no overload takes the lambda, the error is the one of the overload that came closest, at the branch
-- that does not have its result type.
fn pick(x int, f fn(int) -> str) -> str:
    return f(x)
fn pick(x int, f fn(int) -> int) -> str:
    return 'i'

print(pick(1, |x| if (x > 0) 'aa' else 2.5))

--cytest: error
--CompileError: Expected type `str`, got `float`.
--
--@MainPath():8:40:
--print(pick(1, |x| if (x > 0) 'aa' else 2.5))
--                                       ^~~
--
