fn map(items []%T, f fn(T) -> %U) -> []U:
    out := []U{}
    for items |it|:
        out += f(it)
    return out

print(map([]int{1, 2}, |x, y| x + 1))

--cytest: error
--CompileError: Expected a lambda with `1` parameter(s) for `f`. Found `2`.
--
--@MainPath():7:24:
--print(map([]int{1, 2}, |x, y| x + 1))
--                       ^~~~~~~~~~~~
--