fn apply(f fn(int) -> int) -> int:
    return f(1)

c := ^5
apply(|x| x + c.*)

--cytest: error
--CompileError: Expected argument `fn(int) -> int`, found `Func[fn(int) -> int]`, when calling `fn apply(fn(int) -> int) -> int`. A closure is passed to a `Func[fn(...)]` or a `&OpaqueFunc[fn(...)]` parameter.
--
--@MainPath():5:7:
--apply(|x| x + c.*)
--      ^~~~~~~~~~~
--