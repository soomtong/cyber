-- An error inside a branch is not a mismatch of the overload. It is reported.
fn pick(x int, f fn(int) -> str) -> str:
    return f(x)
fn pick(x int, f fn(int) -> int) -> str:
    return 'i'

print(pick(1, |x| if (x > 0) x else nope))

--cytest: error
--CompileError: Undeclared variable `nope`.
--
--@MainPath():7:37:
--print(pick(1, |x| if (x > 0) x else nope))
--                                    ^~~~
--
