-- An assignment that destructs the old element needs exclusive access: `s` points into the old element.
type Foo:
    xs []int

fn (&&Foo) grow():
    for 0..1000 |i|:
        self.xs.append(i)

xs := []Foo{Foo{xs={1, 2, 3}}}
s := &xs[0].xs[0]
xs[0] = Foo{xs={7}}
print(s.*)

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `xs`.
--
--@MainPath():11:1:
--xs[0] = Foo{xs={7}}
--^~~~~~~~~~~~~~~~~~~
--
