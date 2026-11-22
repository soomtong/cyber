xs := []Array[int]{}

--cytest: error
--CompileError: A slice `[]Array[int]` copies its elements, so the element type `Array[int]` can not be `NoCopy`. Use `Array[Array[int]]`, which moves them.
--
--@MainPath():1:7:
--xs := []Array[int]{}
--      ^~~~~~~~~~~~
--
