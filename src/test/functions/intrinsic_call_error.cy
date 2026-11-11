x := 1
y := @bitCast(float, x)

--cytest: error
--CompileError: `@bitCast` is internal to the builtin modules and can not be used in a script.
--
--@MainPath():2:6:
--y := @bitCast(float, x)
--     ^~~~~~~~
--
