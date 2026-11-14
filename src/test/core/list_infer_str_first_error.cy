xs := {'a', 1}

--cytest: error
--CompileError: Expected type `str`, got `int`. A list literal without a type takes the type of its first element and does not convert the others. Write the element type: `[]T{...}`.
--
--@MainPath():1:13:
--xs := {'a', 1}
--            ^
--
