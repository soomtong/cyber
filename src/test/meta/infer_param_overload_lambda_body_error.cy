-- An error inside the body of the lambda is not a mismatch of the overload. It is reported.
fn conv(x int, f fn(int) -> str) -> str:
    return f(x)
fn conv(x %T, f fn(T) -> %U) -> U:
    return f(x)

print(conv(1, |x| x + nope))

--cytest: error
--CompileError: Undeclared variable `nope`.
--
--@MainPath():7:23:
--print(conv(1, |x| x + nope))
--                      ^~~~
--
