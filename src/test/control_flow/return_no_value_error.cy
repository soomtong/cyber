-- A `return` without a value is an error in a function that returns a value.
fn f(x int) -> int:
    if x > 3:
        return
    return 1
print(f(5))

--cytest: error
--CompileError: Expected a return value of type `int`. A `return` without a value is for a function that returns `void` or `!void`.
--
--@MainPath():4:9:
--        return
--        ^~~~~~
--
