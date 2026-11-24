-- An infer parameter inside a computed size of a function type, with a lambda. The error was 'Can not infer
-- function type.' at the lambda.
fn vf(x %T, f fn(T) -> [%N + 1]T) -> int:
    return N

print(vf(4, |x| [3]int{x, x, x}))

--cytest: error
--CompileError: Can not infer the template parameter `N` from the argument for `f`. Declare it as its own parameter (`%N type`) and pass the type in the call.
--
--@MainPath():6:13:
--print(vf(4, |x| [3]int{x, x, x}))
--            ^~~~~~~~~~~~~~~~~~~
--