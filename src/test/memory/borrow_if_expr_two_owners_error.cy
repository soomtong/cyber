-- A borrow from one of two owners is a borrow of both.
y := 7
a := Array[int]{1, 2, 3}
c := false
e := if (c) &y else &a[0]
a << 4
print(e.*)

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `a`.
--
--@MainPath():6:1:
--a << 4
--^
--