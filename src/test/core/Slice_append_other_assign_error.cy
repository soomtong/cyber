xs := []int{1, 2}
var ys []int = {}
ys = xs.append(3)

--cytest: error
--CompileError: `append` changes `xs` in place and returns nothing. Write `xs.append(3)` as a statement, or `xs.appended(3)` for a new list that leaves `xs` as it was.
--
--@MainPath():3:6:
--ys = xs.append(3)
--     ^~~~~~~~~~~~
--