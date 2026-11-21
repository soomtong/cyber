-- A loop borrows what it iterates until it ends, so the body can not pass `self` on as `&&Foo`.
type Foo:
    xs []int

fn (&&Foo) grow():
    for 0..1000 |i|:
        self.xs.append(i)

fn (&&Foo) bad():
    for self.xs |x|:
        self.grow()

f := Foo{xs={1, 2, 3}}
f.bad()

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `self`.
--
--@MainPath():11:9:
--        self.grow()
--        ^~~~
--
