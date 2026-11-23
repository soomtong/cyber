-- The alias does not use its second parameter, so `U` is not in the type of the argument.
type KeyFn[A Any, B Any] = fn(A) -> int

fn keys(items []%T, f KeyFn[T, %U]) -> []int:
    out := []int{}
    for items |it|:
        out += f(it)
    return out

fn round(x float) -> int:
    return int(x)

print(keys([]float{1, 2}, round))

--cytest: error
--CompileError: Can not infer the template parameter `U` from the argument for `f`. Declare it as its own parameter (`%U type`) and pass the type in the call.
--
--@MainPath():13:27:
--print(keys([]float{1, 2}, round))
--                          ^~~~~
--