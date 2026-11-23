-- A closure for overloads that only take a function pointer: the error names the closure.
fn m(x int, f fn(int) -> int) -> int:
    return f(x)
fn m(x str, f fn(str) -> int) -> int:
    return f(x)

k := ^1
print(m(1, |x| x + k.*))

--cytest: error
--CompileError: Expected argument `fn(int) -> int`, found `Func[fn(int) -> int]`, when calling `fn m(int, fn(int) -> int) -> int`. A closure is passed to a `Func[fn(...)]` or a `&OpaqueFunc[fn(...)]` parameter.
--
--@MainPath():8:12:
--print(m(1, |x| x + k.*))
--           ^~~~~~~~~~~
--
