fn map(items []%T, f fn(T) -> %U) -> []U:
    out := []U{}
    for items |it|:
        out += f(it)
    return out

print(map([]int{1, 2}, 3))

--cytest: error
--CompileError: Expected a function for `fn(T) -> %U`. Found `int`.
--
--@MainPath():7:24:
--print(map([]int{1, 2}, 3))
--                       ^
--