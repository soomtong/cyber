-- The function binds `T`. The argument after it must match.
fn rmap(f fn(%T) -> %U, items []T) -> []U:
    out := []U{}
    for items |it|:
        out += f(it)
    return out

fn name(x float) -> str:
    return 'v%{x}'

print(rmap(name, []int{1, 2}))

--cytest: error
--CompileError: Expected type `[]float`. Found `[]int`.
--
--@MainPath():11:18:
--print(rmap(name, []int{1, 2}))
--                 ^~~~~~~~~~~
--