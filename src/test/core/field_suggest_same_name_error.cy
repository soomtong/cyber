xs := []int{1}
n := xs.len

--cytest: error
--CompileError: Field `len` does not exist in `[]int`. Did you mean the method `len()`?
--
--@MainPath():2:9:
--n := xs.len
--        ^~~
--