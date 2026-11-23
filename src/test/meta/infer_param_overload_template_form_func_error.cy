-- The same for a named function.
fn opt(x %T, f fn(T) -> ?%U) -> str:
    return 'option'
fn opt(x str, f fn(str) -> float) -> str:
    return 'float'

fn half(x int) -> float:
    return 0.5

print(opt(1, half))

--cytest: error
--CompileError: Expected template `Option`. Found `Float`.
--
--@MainPath():10:14:
--print(opt(1, half))
--             ^~~~
--
