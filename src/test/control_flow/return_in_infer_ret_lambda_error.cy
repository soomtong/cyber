-- A `return` in the body of a lambda that infers its return type has no type to check its value against.
f := fn(x str) => int.parse(x) !else:
    return 0
print(f('a'))

--cytest: error
--CompileError: `return` can not leave a lambda whose return type is inferred from its body: the return type is not known yet. Declare the return type of the lambda (`fn(x T) -> U => expr`).
--
--@MainPath():3:5:
--    return 0
--    ^~~~~~~~
--