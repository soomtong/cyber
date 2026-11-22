-- A vector of borrows can not outlive what it borrows.
x := 7
var r [1]&int = [1]&int{&x}
if true:
    y := 5
    r = [1]&int{&y}
print(r[0].*)

--cytest: error
--CompileError: `r` can not outlive `y`.
--
--@MainPath():6:9:
--    r = [1]&int{&y}
--        ^~~~~~~~~~~
--