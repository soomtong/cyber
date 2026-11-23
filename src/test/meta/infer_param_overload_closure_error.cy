-- A closure for overloads that only take a function pointer, where the closest one infers template parameters.
fn m(x %T, f fn(T) -> %U) -> U:
    return f(x)
fn m(x str, f fn(str) -> int) -> int:
    return f(x)

k := ^1
print(m(1, |x| x + k.*))

--cytest: error
--CompileError: Expected a function for `fn(T) -> %U`. Found the closure `Func[fn(int) -> int]`. A closure is passed to a `Func[fn(...)]` or a `&OpaqueFunc[fn(...)]` parameter.
--
--@MainPath():8:12:
--print(m(1, |x| x + k.*))
--           ^~~~~~~~~~~
--
