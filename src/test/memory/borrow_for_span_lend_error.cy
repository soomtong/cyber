-- A capture of a span of a vector keeps the owners of the vector borrowed.
a := Array[int]{1, 2}
x := 7
var r &int = &x
if true:
    xs := [2]&int{&x, &a[0]}
    for xs[..] |p|:
        r = p
a << 4
print(r.*)

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `a`.
--
--@MainPath():9:1:
--a << 4
--^
--