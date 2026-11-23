-- An error in the block is not a mismatch of the overload. It is reported, also after a `return` that does
-- not have the result type.
fn pick(x int, f fn(int) -> str) -> str:
    return f(x)
fn pick(x int, f fn(int) -> int) -> str:
    return 'i'

r := pick(1, |x|):
    if x > 5:
        return 3
    return x + nope
print(r)

--cytest: error
--CompileError: Undeclared variable `nope`.
--
--@MainPath():11:16:
--    return x + nope
--               ^~~~
--
