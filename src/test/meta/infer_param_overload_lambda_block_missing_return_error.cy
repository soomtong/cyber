-- A block without a `return` does not match an overload that needs a result. When no overload takes the
-- lambda, the error of the overload that came closest is reported.
fn pick(x int, f fn(int) -> str) -> str:
    return f(x)
fn pick(x int, f fn(int) -> int) -> str:
    return 'i'

r := pick(1, |x|):
    print(x)
print(r)

--cytest: error
--CompileError: Missing return statement.
--
--@MainPath():8:14:
--r := pick(1, |x|):
--             ^~~
--
