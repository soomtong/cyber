-- An error inside the body is reported for an overload that infers template parameters too.
fn conv(x %T, f fn(T) -> str) -> str:
    return f(x)
fn conv(x float, f fn(float) -> float) -> str:
    return 'f'

print(conv(1, |x| x + nope))

--cytest: error
--CompileError: Undeclared variable `nope`.
--
--@MainPath():7:23:
--print(conv(1, |x| x + nope))
--                      ^~~~
--
