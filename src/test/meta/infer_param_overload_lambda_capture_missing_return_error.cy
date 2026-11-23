-- No overload takes a block without a result that captures a variable: the error of the overload that came
-- closest is reported, and the captures of the lambda are released.
fn run(x int, f Func[fn(int) -> int]) -> str:
    return 'int %{f(x)}'
fn run(x str, f Func[fn(str) -> int]) -> str:
    return 'str'

k := ^10
r := run(1, |x|):
    k.* = k.* + x
print(r)

--cytest: error
--CompileError: Missing return statement.
--
--@MainPath():9:13:
--r := run(1, |x|):
--            ^~~
--
