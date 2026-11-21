-- An assignment that destructs the old value of a field needs exclusive access: `s` points into the old array.
type Foo:
    xs []int

fn (&&Foo) grow():
    for 0..1000 |i|:
        self.xs.append(i)

g := Foo{xs={1, 2, 3}}
s := &g.xs[0]
g.xs = {7}
print(s.*)

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `g`.
--
--@MainPath():11:1:
--g.xs = {7}
--^~~~~~~~~~
--
