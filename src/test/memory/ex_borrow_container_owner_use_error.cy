-- The exclusive borrow in a borrow container can not be used while a local borrows from the owner directly.
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
--CompileError: Expected exclusive access. There is another active borrow to `f`.
--
--@MainPath():15:1:
--h.r.grow()
--^~~
--
