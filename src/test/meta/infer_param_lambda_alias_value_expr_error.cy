-- The alias computes with its value parameter. The parameter can not be read back from the result type.
type V2[const N int, T Any] = fn(T) -> [N + 1]T

fn vf(x %T, f V2[%N, T]) -> int:
    return f(x).len()

print(vf(4, |x| [3]int{x, x, x}))

--cytest: error
--CompileError: Can not infer the template parameter `N` from the argument for `f`. Declare it as its own parameter (`%N type`) and pass the type in the call.
--
--@MainPath():7:13:
--print(vf(4, |x| [3]int{x, x, x}))
--            ^~~~~~~~~~~~~~~~~~~
--