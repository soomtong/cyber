fn two(a %T, b %T) -> T:
    return a

print(two(1, 2))

--cytest: error
--CompileError: The template parameter `T` is already declared. Write `T` without `%` to use it.
--
--@MainPath():1:16:
--fn two(a %T, b %T) -> T:
--               ^~
--