-- A closure is not a function pointer.
fn map(items []%T, f fn(T) -> %U) -> []U:
    out := []U{}
    for items |it|:
        out += f(it)
    return out

k := ^1
print(map([]int{1, 2}, |x| x + k.*))

--cytest: error
--CompileError: Expected a function for `fn(T) -> %U`. Found the closure `Func[fn(int) -> int]`. A closure is passed to a `Func[fn(...)]` or a `&OpaqueFunc[fn(...)]` parameter.
--
--@MainPath():9:24:
--print(map([]int{1, 2}, |x| x + k.*))
--                       ^~~~~~~~~~~
--