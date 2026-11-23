type MapFn[T Any, U Any] = fn(T) -> U

fn map(items []%T, f MapFn[T, %U]) -> []U:
    out := []U{}
    for items |it|:
        out += f(it)
    return out

fn name(x float) -> str:
    return 'v%{x}'

print(map([]float{1, 2}, name))

--cytest: error
--CompileError: Can not infer the template parameter `U` from the argument for `f`. Declare it as its own parameter (`%U type`) and pass the type in the call.
--
--@MainPath():12:26:
--print(map([]float{1, 2}, name))
--                         ^~~~
--
