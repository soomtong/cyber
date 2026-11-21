-- A borrow container that holds an exclusive borrow is checked like the borrow when it is passed on: the callee can
-- use the exclusive borrow.
type Foo:
    xs []int

fn (&&Foo) grow():
    for 0..1000 |i|:
        self.xs.append(i)

type Holder:
    r &&Foo

fn go(x Holder):
    x.r.grow()

fn foo(r &&Foo):
    s := &r.xs[0]
    go(Holder{r=r})
    print(s.*)

f := Foo{xs={1, 2, 3}}
foo(&&f)

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `r`.
--
--@MainPath():18:8:
--    go(Holder{r=r})
--       ^~~~~~~~~~~
--
