-- The return type of a lambda that infers it is the type of its body. A `return` without a value needs a `void` body.
f := fn(x str) => int.parse(x) !else:
    return
print(f('a'))

--cytest: error
--CompileError: Expected a return value of type `int`. A `return` without a value is for a function that returns `void` or `!void`.
--
--@MainPath():3:5:
--    return
--    ^~~~~~
--
