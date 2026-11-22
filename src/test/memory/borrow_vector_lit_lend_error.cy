-- A vector of borrows keeps what it borrows borrowed.
a := Array[int]{1, 2}
xs := [1]&int{&a[0]}
a << 4
print(xs[0].*)

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `a`.
--
--@MainPath():4:1:
--a << 4
--^
--