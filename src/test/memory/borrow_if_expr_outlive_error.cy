x := 1
var r &int = &x
begin:
    z := 4
    r = if (x == 1) &z else &x
print(r.*)

--cytest: error
--CompileError: `r` can not outlive `z`.
--
--@MainPath():5:9:
--    r = if (x == 1) &z else &x
--        ^~~~~~~~~~~~~~~~~~~~~~
--
