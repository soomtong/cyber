-- No overload takes the second argument: the error is the one of the overload that came closest.
fn pair(x %T, y str) -> str:
    return 'str'
fn pair(x str, y float) -> str:
    return 'float'

print(pair(1, true))

--cytest: error
--CompileError: Expected type `str`. Found `bool`.
--
--@MainPath():7:15:
--print(pair(1, true))
--              ^~~~
--
