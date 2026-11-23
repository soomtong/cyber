type MapFn[A Any, B Any] = fn(A) -> B

fn map(items []%T, f MapFn[T, %U]) -> []U:
    out := []U{}
    for items |it|:
        out += f(it)
    return out

fn name(x float) -> str:
    return 'v%{x}'

print(map([]int{1, 2}, name))

--cytest: error
--CompileError: Expected type `fn(int) -> str`. Found `fn(float) -> str`.
--
--@MainPath():12:24:
--print(map([]int{1, 2}, name))
--                       ^~~~
--