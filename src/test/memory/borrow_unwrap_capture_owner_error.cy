-- An unwrap capture can not outlive what the option borrows.
x := 7
var r &int = &x
if true:
    y := 5
    o := ?&int(&y)
    if o |q|:
        r = q
print(r.*)

--cytest: error
--CompileError: `r` can not outlive `y`.
--
--@MainPath():8:13:
--        r = q
--            ^
--