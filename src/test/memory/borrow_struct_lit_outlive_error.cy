type R:
    r &int

z := 1
var r R = R{r=&z}
begin:
    y := 42
    r = R{r=&y}
print(r.r.*)

--cytest: error
--CompileError: `r` can not outlive `y`.
--
--@MainPath():8:9:
--    r = R{r=&y}
--        ^~~~~~~
--