type Foo:
    xs []int

fn (scope &Foo) first() -> scope &int:
    return &self.xs[0]

fn (&&Foo) grow():
    for 0..1000 |i|:
        self.xs.append(i)

f := Foo{xs={1, 2, 3}}
r := &&f
s := r.first()
r.grow()
print(s.*)

--cytest: error
--CompileError: Cannot borrow `f`. There is an active exclusive borrow to it.
--
--@MainPath():13:6:
--s := r.first()
--     ^~~~~~~~~
--
