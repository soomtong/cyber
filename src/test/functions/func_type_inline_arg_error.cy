fn apply(f fn(int) -> int) -> int:
    return f(1)

fn ident(s str) -> str:
    return s

apply(ident)

--cytest: error
--CompileError: Expected argument `fn(int) -> int`, found `fn(str) -> str`, when calling `fn apply(fn(int) -> int) -> int`.
--
--@MainPath():7:7:
--apply(ident)
--      ^~~~~
--