-- When no overload takes the lambda, the error is the one of the overload that came closest, at the `return`
-- that does not have its result type.
fn pick(x int, f fn(int) -> str) -> str:
    return f(x)
fn pick(x int, f fn(int) -> int) -> str:
    return 'i'

r := pick(1, |x|):
    if x > 5:
        return 'big'
    return 2.5
print(r)

--cytest: error
--CompileError: Expected type `str`, got `float`.
--
--@MainPath():11:12:
--    return 2.5
--           ^~~
--
