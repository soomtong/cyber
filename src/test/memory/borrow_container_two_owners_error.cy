-- A borrow container borrows from every local that one of its fields borrows.
type Foo:
    xs []int

fn (&&Foo) grow():
    for 0..1000 |i|:
        self.xs.append(i)

type Holder:
    r &&Foo

type Pair:
    a &&Foo
    b &&Foo

x := Foo{xs={1}}
y := Foo{xs={2}}
p := Pair{a=&&x, b=&&y}
t := &y.xs[0]
p.b.grow()
print(t.*)

--cytest: error
--CompileError: Cannot borrow `y`. There is an active exclusive borrow to it.
--
--@MainPath():19:7:
--t := &y.xs[0]
--      ^~~~
--
