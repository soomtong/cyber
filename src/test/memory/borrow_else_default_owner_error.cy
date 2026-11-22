-- The default of `?else` can give the borrow.
a := Array[int]{1, 2, 3}
var o ?&int = none
e := o ?else &a[0]
a << 4
print(e.*)

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `a`.
--
--@MainPath():5:1:
--a << 4
--^
--