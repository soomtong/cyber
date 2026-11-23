fn map(items []%T, f fn(T) -> %U) -> []U:
    out := []U{}
    for items |it|:
        out += f(it)
    return out

print(map([]int{1, 2}, fn(x float) => x))

--cytest: error
--CompileError: Expected type `fn(int) -> float`. Found `fn(float) -> float`.
--
--@MainPath():7:36:
--print(map([]int{1, 2}, fn(x float) => x))
--                                   ^~~~
--