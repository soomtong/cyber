fn apply(f fn() -> int) -> int:
    return f()

print(apply(|a| 1))

--cytest: error
--CompileError: Expected a lambda with `0` parameter(s) for `fn() -> int`. Found `1`. A lambda without parameters is written `|_| expr`.
--
--@MainPath():4:13:
--print(apply(|a| 1))
--            ^~~~~
--
