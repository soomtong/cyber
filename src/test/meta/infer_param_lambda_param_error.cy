-- The lambda is typed before the argument that binds `T`.
fn rmap(f fn(%T) -> %U, items []T) -> []U:
    out := []U{}
    for items |it|:
        out += f(it)
    return out

print(rmap(|x| x + 1, []int{1, 2}))

--cytest: error
--CompileError: Can not infer the template parameter `T` from the lambda for `f`. The type of the lambda parameter `x` must be known from the arguments before the lambda. Declare the types of the lambda (`fn(x T) -> U: ...`), or declare `%T type` as its own parameter and pass the type in the call.
--
--@MainPath():8:12:
--print(rmap(|x| x + 1, []int{1, 2}))
--           ^~~~~~~~~
--