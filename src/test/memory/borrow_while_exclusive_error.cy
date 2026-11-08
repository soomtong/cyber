a := Array[int]{1, 2, 3}
ex := &&a
r := &a[0]
ex.append(4)

--cytest: error
--CompileError: Cannot borrow `a`. There is an active exclusive borrow to it.
--
--@MainPath():3:7:
--r := &a[0]
--      ^
--
