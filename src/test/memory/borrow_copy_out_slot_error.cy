-- A borrow of the slot of a borrow in a container points into the container.
type RI = &int

type H:
    a &int
    b &int

y := 5
x := H{a=&y, b=&y}
var pp &RI = &x.b
if true:
    h := H{a=&y, b=&y}
    pp = &h.b
print(pp.*.*)

--cytest: error
--CompileError: `pp` can not outlive `h`.
--
--@MainPath():13:10:
--    pp = &h.b
--         ^~~~
--
