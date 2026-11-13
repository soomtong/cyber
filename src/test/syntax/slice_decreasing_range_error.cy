a := []int{1, 2, 3}
print(a[2..>0])

--cytest: error
--CompileError: A decreasing range can not be a slice index.
--
--@MainPath():2:9:
--print(a[2..>0])
--        ^~~~~
--