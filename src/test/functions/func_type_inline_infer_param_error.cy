-- A lambda with a block does not infer its result type, so it can not bind `U`.
fn map(items []%T, f fn(T) -> %U) -> []U:
    out := []U{}
    for items |it|:
        out += f(it)
    return out

print(map([]int{1, 2}, |x|)):
    return x + 1

--cytest: error
--CompileError: Can not infer the template parameter `U` from the lambda for `f`. The result type of a lambda with a block is not inferred. Use an expression lambda (`|x| expr`), declare the types of the lambda (`fn(x T) -> U:`), or declare `%U type` as its own parameter and pass the type in the call.
--
--@MainPath():8:24:
--print(map([]int{1, 2}, |x|)):
--                       ^~~
--