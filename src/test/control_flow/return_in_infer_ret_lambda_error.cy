-- The return type of a lambda that infers it is the type of its body. A `return` in the body returns that type.
f := fn(x str) => int.parse(x) !else:
    return 'none'
print(f('a'))

--cytest: error
--CompileError: Expected type `int`, got `str`.
--
--@MainPath():3:12:
--    return 'none'
--           ^~~~~~
--