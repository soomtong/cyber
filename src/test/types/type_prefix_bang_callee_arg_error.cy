x := 1
a := ?!int(x)

--cytest: error
--CompileError: Expected argument `?!int`, found `int`, when calling `fn @init(scope ?!int) -> scope ?!int`.
--
--@MainPath():2:12:
--a := ?!int(x)
--           ^
--
