-- A copy that is read out of a container keeps every owner of the container borrowed.
type H:
    a &int
    b &int

a := Array[int]{1, 2}
y := 5
var r &int = &y
if true:
    h := H{a=&a[0], b=&y}
    r = h.b
a << 4
print(r.*)

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `a`.
--
--@MainPath():12:1:
--a << 4
--^
--
