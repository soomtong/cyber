-- An infer parameter inside a computed size of a function type. It can not be read back from the type of the
-- argument. The error said 'a template parameter' and named `%T`.
fn vf(x %T, f fn(T) -> [%N + 1]T) -> int:
    return N

fn three(x int) -> [3]int:
    return {x, x, x}

print(vf(4, three))

--cytest: error
--CompileError: Can not infer the template parameter `N` from the argument for `f`. Declare it as its own parameter (`%N type`) and pass the type in the call.
--
--@MainPath():9:13:
--print(vf(4, three))
--            ^~~~~
--