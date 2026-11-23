-- A new infer parameter can not be declared inside a function type.
fn map(items []%T, f fn(T) -> %U) -> []U:
    out := []U{}
    for items |it|:
        out += f(it)
    return out

print(map([]int{1, 2}, |x| x + 1))

--cytest: error
--CompileError: Can not infer the template parameter `U` from the argument for `f`. Declare it as its own parameter (`%U type`) and pass the type in the call.
--
--@MainPath():8:24:
--print(map([]int{1, 2}, |x| x + 1))
--                       ^~~~~~~~~
--