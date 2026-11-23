-- An error inside the lambda is reported right away, not taken as a mismatch of the overload.
fn opt(x %T, f fn(T) -> ?%U) -> str:
    return 'option'
fn opt(x float, f fn(float) -> float) -> str:
    return 'float'

print(opt(1, |x| x + missing))

--cytest: error
--CompileError: Undeclared variable `missing`.
--
--@MainPath():7:22:
--print(opt(1, |x| x + missing))
--                     ^~~~~~~
--
