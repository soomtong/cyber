-- A copy of a borrow of a container points into the container and can not outlive it.
type H:
    a &int
    b int

y := 5
h0 := H{a=&y, b=1}
var r &H = &h0
if true:
    h := H{a=&y, b=42}
    hr := &h
    r = hr
print(r.b)

--cytest: error
--CompileError: `r` can not outlive `h`.
--
--@MainPath():12:9:
--    r = hr
--        ^~
--
