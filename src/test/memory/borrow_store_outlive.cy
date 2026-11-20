use test

-- A borrow can be stored in a field, an option or through an `if` expression when the borrowed local lives as long.
type View:
    a &int

type Outer:
    v View

fn (&&Outer) set(scope p &int):
    self.v = View{a=p}

x := 1
y := 2
o := Outer{v=View{a=&x}}
o.v = View{a=&y}
test.eq(2, o.v.a.*)
o.v.a = &x
test.eq(1, o.v.a.*)
o.set(&y)
test.eq(2, o.v.a.*)

var p ?&int = none
p = &y
test.eq(2, p.?.*)
r := if (x == 1) &x else &y
test.eq(1, r.*)

begin:
    z := 5
    q := if (x == 1) &z else &y
    test.eq(5, q.*)
    var w ?View = none
    w = View{a=&z}
    test.eq(5, w.?.a.*)
    inner := Outer{v=View{a=&x}}
    inner.v = View{a=&z}
    test.eq(5, inner.v.a.*)

--cytest: pass
