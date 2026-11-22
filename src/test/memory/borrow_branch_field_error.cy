-- A borrow from one of two owners that a field takes is a loan of both owners.
type Holder:
    r &int

a := Array[int]{1, 2, 3}
y := 7
h := Holder{r=&y}
k := 1
h.r = if (k == 2) &y else &a[0]
a << 4
print(h.r.*)

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `a`.
--
--@MainPath():10:1:
--a << 4
--^
--