-- The template parameter that is known must match the function. `T` is `int` from the first argument.
fn map(items []%T, f fn(T) -> %U) -> []U:
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
--@MainPath():11:24:
--print(map([]int{1, 2}, name))
--                       ^~~~
--