-- A borrow container that holds an exclusive borrow keeps exclusive access to the owner like the borrow itself.
type Foo:
    xs []int

fn (&&Foo) grow():
    for 0..1000 |i|:
        self.xs.append(i)

type Holder:
    r &&Foo

f := Foo{xs={1, 2, 3}}
h := Holder{r=&&f}
s := &f.xs[0]
h.r.grow()
print(s.*)

--cytest: error
--CompileError: Cannot borrow `f`. There is an active exclusive borrow to it.
--
--@MainPath():14:7:
--s := &f.xs[0]
--      ^~~~
--
