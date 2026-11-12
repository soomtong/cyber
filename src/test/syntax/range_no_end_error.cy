a := []int{1, 2, 3}
b := a[..-1]

--cytest: error
--CompileError: Expected range end. A range without an end is only allowed as a slice index.
--
--@MainPath():2:8:
--b := a[..-1]
--       ^~
--