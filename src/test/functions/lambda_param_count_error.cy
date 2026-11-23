-- An inferred lambda declares as many parameters as the function type.
fn apply(f fn(int) -> int) -> int:
    return f(1)

print(apply(|a, b| a))

--cytest: error
--CompileError: Expected a lambda with `1` parameter(s) for `fn(int) -> int`. Found `2`.
--
--@MainPath():5:13:
--print(apply(|a, b| a))
--            ^~~~~~~~
--
