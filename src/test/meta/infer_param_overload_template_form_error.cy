-- When no overload takes the argument, the error is the one of the overload that came closest: here the
-- overload that infers template parameters.
fn opt(x %T, f fn(T) -> ?%U) -> str:
    return 'option'
fn opt(x str, f fn(str) -> float) -> str:
    return 'float'

print(opt(1, |x| 1.5))

--cytest: error
--CompileError: Expected template `Option`. Found `Float`.
--
--@MainPath():8:14:
--print(opt(1, |x| 1.5))
--             ^~~~~~~
--
