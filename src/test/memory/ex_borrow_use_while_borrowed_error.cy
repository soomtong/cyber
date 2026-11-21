-- An exclusive borrow that a local or a parameter holds can not be passed on while another local borrows through it:
-- `r.grow()` would free what `s` points to.
type Foo:
    xs []int

fn (&&Foo) grow():
    for 0..1000 |i|:
        self.xs.append(i)

fn foo(r &&Foo):
    s := &r.xs[0]
    r.grow()
    print(s.*)

f := Foo{xs={1, 2, 3}}
foo(&&f)

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `r`.
--
--@MainPath():12:5:
--    r.grow()
--    ^
--
