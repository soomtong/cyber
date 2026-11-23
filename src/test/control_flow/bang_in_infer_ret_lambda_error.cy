-- The return type of the lambda is the type of its body, so a `!` in the body has no type to return the error as.
f := fn(x str) => int.parse(x)!
print(f('1'))

--cytest: error
--CompileError: `!` can not leave a lambda whose return type is inferred from its body: the return type is not known yet. Declare the return type of the lambda (`fn(x T) -> !U => expr`), or handle the error here with `!else` or `try`.
--
--@MainPath():2:19:
--f := fn(x str) => int.parse(x)!
--                  ^~~~~~~~~~~~~
--