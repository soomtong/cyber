fn apply(f fn(int, int) -> int) -> int:
    return f(1, 2)

r := apply(|a|):
    return a

--cytest: error
--CompileError: Expected a lambda with `2` parameter(s) for `fn(int, int) -> int`. Found `1`.
--
--@MainPath():4:12:
--r := apply(|a|):
--           ^~~
--
