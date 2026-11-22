-- A borrow of an unwrap capture ends with the branch.
x := 7
var r &int = &x
o := ?int(3)
if o |q|:
    r = &q
print(r.*)

--cytest: error
--CompileError: `r` can not outlive `q`.
--
--@MainPath():6:9:
--    r = &q
--        ^~
--