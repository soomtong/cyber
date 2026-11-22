-- The option of `?else` can give the borrow, even with a default that borrows from another local.
y := 7
a := Array[int]{1, 2, 3}
var o ?&int = &a[0]
e := o ?else &y
a << 4
print(e.*)

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `a`.
--
--@MainPath():6:1:
--a << 4
--^
--