-- A shared borrow gives no exclusive access to what is behind it, also when that is an exclusive borrow.
type Foo:
    xs []int

fn (&&Foo) grow():
    for 0..1000 |i|:
        self.xs.append(i)

type Holder:
    r &&Foo

fn foo(r &&Foo):
    b := &r
    g := fn() => b.*.grow()
    s := &r.xs[0]
    g()
    print(s.*)

f := Foo{xs={1, 2, 3}}
foo(&&f)

--cytest: error
--CompileError: Cannot use an exclusive borrow that is read through a shared borrow.
--
--@MainPath():14:18:
--    g := fn() => b.*.grow()
--                 ^~~
--
