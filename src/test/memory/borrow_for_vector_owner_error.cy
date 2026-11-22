-- A `for` capture can not outlive what the vector borrows.
x := 7
var r &int = &x
if true:
    y := 5
    xs := [1]&int{&y}
    for xs |p|:
        r = p
print(r.*)

--cytest: error
--CompileError: `r` can not outlive `y`.
--
--@MainPath():8:13:
--        r = p
--            ^
--