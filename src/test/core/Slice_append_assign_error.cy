out := []int{1, 2}
out = out.append(3)

--cytest: error
--CompileError: `append` changes `out` in place and returns nothing. Write `out.append(3)` as a statement.
--
--@MainPath():2:7:
--out = out.append(3)
--      ^~~~~~~~~~~~~
--