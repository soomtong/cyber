-- A lambda has no type without a function type to take its parameter types from.
fn id(x %T) -> T:
    return x

print(id(|x| x + 1))

--cytest: error
--CompileError: Can not infer function type. Consider using an explicit `fn` declaration.
--
--@MainPath():5:10:
--print(id(|x| x + 1))
--         ^~~~~~~~~
--