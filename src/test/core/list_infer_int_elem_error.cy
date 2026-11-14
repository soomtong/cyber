xs := {1.5, 2}

--cytest: error
--CompileError: Expected type `float`, got `int`. A list literal without a type takes the type of its first element and does not convert the others. Write the element type: `[]T{...}`.
--
--@MainPath():1:13:
--xs := {1.5, 2}
--            ^
--