-- A borrow of a place that is read through a borrow of a container (`&hr.b` of `hr := &h`) points into the
-- container and can not outlive it.
type H:
    a &int
    b int

y := 5
var p &int = &y
if true:
    h := H{a=&y, b=42}
    hr := &h
    p = &hr.b
print(p.*)

--cytest: error
--CompileError: `p` can not outlive `h`.
--
--@MainPath():12:9:
--    p = &hr.b
--        ^~~~~
--
