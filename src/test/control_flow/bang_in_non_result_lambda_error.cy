f := fn() -> int:
    n := int.parse('1')!
    return n

--cytest: error
--CompileError: Expected a `!T` or `error` return type for `!`. The lambda returns `int`, so `!` can not pass the error on. Declare it `-> !int`, or handle the error here with `!else` or `try`.
--
--@MainPath():2:10:
--    n := int.parse('1')!
--         ^~~~~~~~~~~~~~~
--
