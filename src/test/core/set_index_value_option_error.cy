m := Map[str, int]{}
h := 'ab'.index('b')
m['a'] = h

--cytest: error
--CompileError: An element of `Map[str, int]` must be `int`, got `?int`. Unwrap it first: `if x |v|:` or `x.?`.
--
--@MainPath():3:10:
--m['a'] = h
--         ^
--
