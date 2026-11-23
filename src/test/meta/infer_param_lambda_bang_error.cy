-- The result type of an inferred lambda is the type of its body, so a `!` in the body can not return the error.
fn map(items []%T, f fn(T) -> %U) -> []U:
    out := []U{}
    for items |it|:
        out += f(it)
    return out

print(map([]str{'1'}, |x| int.parse(x)!))

--cytest: error
--CompileError: `!` can not leave a lambda whose return type is inferred from its body: the return type is not known yet. Declare the return type of the lambda (`fn(x T) -> !U => expr`), or handle the error here with `!else` or `try`.
--
--@MainPath():8:27:
--print(map([]str{'1'}, |x| int.parse(x)!))
--                          ^~~~~~~~~~~~~
--