-- A borrow that is stored in a field of a borrow container is counted for the local it borrows from.
type Foo:
    xs []int

fn (&&Foo) grow():
    for 0..1000 |i|:
        self.xs.append(i)

type Holder:
    r &&Foo

f := Foo{xs={1, 2, 3}}
g := Foo{xs={4}}
h := Holder{r=&&g}
h.r = &&f
s := &f.xs[0]
h.r.grow()
print(s.*)

--cytest: error
--CompileError: Cannot borrow `f`. There is an active exclusive borrow to it.
--
--@MainPath():16:7:
--s := &f.xs[0]
--      ^~~~
--
