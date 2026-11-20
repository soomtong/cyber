-- A borrow taken through a local that holds an exclusive borrow can not be kept in a local: `r.grow()` would free
-- what `s` points to.
type Foo:
    xs []int

fn (&&Foo) grow():
    for 0..1000 |i|:
        self.xs.append(i)

f := Foo{xs={1, 2, 3}}
r := &&f
s := &r.xs[0]
r.grow()
print(s.*)

--cytest: error
--CompileError: Cannot borrow `f`. There is an active exclusive borrow to it.
--
--@MainPath():12:6:
--s := &r.xs[0]
--     ^~~~~~~~
--
