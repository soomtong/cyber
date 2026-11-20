type View:
    a &int

var o ?View = none
begin:
    y := 4
    o = View{a=&y}
print(o.?.a.*)

--cytest: error
--CompileError: `o` can not outlive `y`.
--
--@MainPath():7:9:
--    o = View{a=&y}
--        ^~~~~~~~~~
--
