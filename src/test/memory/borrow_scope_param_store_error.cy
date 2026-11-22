-- A function can store its `scope` parameter behind another borrow parameter. The value behind that argument then
-- can not outlive what the `scope` argument borrows.
type View:
    a &int

type Outer:
    v View

fn (&&Outer) set(scope p &int):
    self.v = View{a=p}

fn run():
    x := 1
    o := Outer{v=View{a=&x}}
    if true:
        z := 42
        o.set(&z)
    print(o.v.a.*)

run()

--cytest: error
--CompileError: `o` can not outlive `z`.
--
--@MainPath():17:15:
--        o.set(&z)
--              ^~
--
