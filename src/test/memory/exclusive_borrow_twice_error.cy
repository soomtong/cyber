a := Array[int]{1, 2, 3}
ex := &&a
ex2 := &&a
ex.append(4)

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `a`.
--
--@MainPath():3:8:
--ex2 := &&a
--       ^~~
--
