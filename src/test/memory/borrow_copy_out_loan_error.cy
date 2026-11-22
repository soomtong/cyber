-- A copy that is read out of a container keeps a borrow that is stored in it later.
type H:
    a &int
    b &int

y := 5
var r &int = &y
if true:
    z := 2
    if true:
        var h H = H{a=&y, b=&y}
        h.b = &z
        r = h.b
print(r.*)

--cytest: error
--CompileError: `r` can not outlive `z`.
--
--@MainPath():13:13:
--        r = h.b
--            ^~~
--
