-- A copy of a borrow keeps the owner borrowed after the original's last use.
a := Array[int]{1, 2, 3}
r := &a[0]
r2 := r
a << 1
print(r2.*)

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `a`.
--
--@MainPath():5:1:
--a << 1
--^
--