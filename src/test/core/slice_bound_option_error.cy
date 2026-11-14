s := 'a#b'
h := s.index('#')
print(s[h..])

--cytest: error
--CompileError: A slice bound must be `int`, got `?int`. Unwrap it first: `if s.index(x) |i|:` or `x.?`.
--
--@MainPath():3:9:
--print(s[h..])
--        ^
--
