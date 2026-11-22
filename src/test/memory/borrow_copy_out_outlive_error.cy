-- A copy that is read out of a container can not outlive what the container borrows.
type H:
    a &int
    b &int

x := 7
var r &int = &x
if true:
    y := 5
    if true:
        h := H{a=&x, b=&y}
        r = h.b
print(r.*)

--cytest: error
--CompileError: `r` can not outlive `y`.
--
--@MainPath():12:13:
--        r = h.b
--            ^~~
--
