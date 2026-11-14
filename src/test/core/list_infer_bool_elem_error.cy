xs := {1, true}

--cytest: error
--CompileError: Expected type `int`, got `bool`. A list literal without a type takes the type of its first element and does not convert the others. Write the element type: `[]T{...}`.
--
--@MainPath():1:11:
--xs := {1, true}
--          ^~~~
--
