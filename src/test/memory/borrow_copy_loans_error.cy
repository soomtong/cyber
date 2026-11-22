-- A copy of a borrow container keeps all of its owners borrowed.
type H:
    a &int
    b &int

a := Array[int]{1, 2}
x := 7
var r H = H{a=&x, b=&x}
if true:
    h := H{a=&x, b=&a[0]}
    r = h
a << 4
print(r.b.*)

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `a`.
--
--@MainPath():12:1:
--a << 4
--^
--