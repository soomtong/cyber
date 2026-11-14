xs := {1, 2, 3}
h := 'ab'.index('b')
print(xs[h])

--cytest: error
--CompileError: An index must be `int`, got `?int`. Unwrap it first: `if s.index(x) |i|:` or `x.?`.
--
--@MainPath():3:10:
--print(xs[h])
--         ^
--
