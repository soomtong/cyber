type View:
    a &int

type Outer:
    v View

fn (&&Outer) set():
    z := 4
    self.v = View{a=&z}

x := 1
o := Outer{v=View{a=&x}}
o.set()
print(o.v.a.*)

--cytest: error
--CompileError: The value behind `self` can not outlive `z`.
--
--@MainPath():9:14:
--    self.v = View{a=&z}
--             ^~~~~~~~~~
--
