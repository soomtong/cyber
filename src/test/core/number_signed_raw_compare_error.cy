var s i8 = -1
var r r64 = 5
print(s < r)

--cytest: error
--CompileError: Expected type `i8`, got `r64`.
--
--@MainPath():3:11:
--print(s < r)
--          ^
--
