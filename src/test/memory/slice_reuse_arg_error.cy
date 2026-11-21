-- A new-list method on the last use of a local is checked as its in-place method. The error names the method that
-- the script wrote.
xs := []int{1}
ys := xs.inserted(1)
print(ys.len())

--cytest: error
--CompileError: Expected `3` arguments, found `2`, when calling the function `fn inserted(&[]int, int, int) -> []int`.
--
--@MainPath():4:7:
--ys := xs.inserted(1)
--      ^~~~~~~~~~~~~~
--