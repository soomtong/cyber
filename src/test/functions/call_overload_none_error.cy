-- No overload takes `none`: the error is the one of the first overload.
fn h(x int) -> str:
    return 'int'
fn h(x str) -> str:
    return 'str'

print(h(none))

--cytest: error
--CompileError: Expected `?T` to infer `none` value, found `Int`.
--
--@MainPath():7:9:
--print(h(none))
--        ^~~~
--
