a := Array[int]{1, 2, 3}
ex := &&a
print(a.len())

--cytest: error
--CompileError: Cannot borrow `a`. There is an active exclusive borrow to it.
--
--@MainPath():3:7:
--print(a.len())
--      ^
--
