type View:
    a &int

type Outer:
    v View

x := 1
o := Outer{v=View{a=&x}}
begin:
    z := 4
    o.v = View{a=&z}
print(o.v.a.*)

--cytest: error
--CompileError: `o` can not outlive `z`.
--
--@MainPath():11:11:
--    o.v = View{a=&z}
--          ^~~~~~~~~~
--
