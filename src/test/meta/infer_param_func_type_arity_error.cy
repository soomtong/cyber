fn map(items []%T, f fn(T) -> %U) -> []U:
    out := []U{}
    for items |it|:
        out += f(it)
    return out

fn add(a int, b int) -> int:
    return a + b

print(map([]int{1, 2}, add))

--cytest: error
--CompileError: Expected a function with `1` parameter(s) for `fn(T) -> %U`. Found `fn(int, int) -> int`.
--
--@MainPath():10:24:
--print(map([]int{1, 2}, add))
--                       ^~~
--