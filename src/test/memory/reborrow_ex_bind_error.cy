type Foo:
    xs []int

fn (&&Foo) grow():
    for 0..1000 |i|:
        self.xs.append(i)

f := Foo{xs={1, 2, 3}}
r := &&f
q := &&r.xs
r.grow()
q.append(5)

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `f`.
--
--@MainPath():10:6:
--q := &&r.xs
--     ^~~~~~
--
