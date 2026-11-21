-- A borrow of a borrow container can not outlive the container, even when the owner that the container borrows
-- from lives longer.
type Foo:
    xs []int

fn (&&Foo) grow():
    for 0..1000 |i|:
        self.xs.append(i)

type Holder:
    r &&Foo

fn (&&Holder) push(n int):
    self.r.xs.append(n)

f := Foo{xs={1, 2, 3}}
g := Foo{xs={7}}
h0 := Holder{r=&&g}
p := &&h0
begin:
    h := Holder{r=&&f}
    p = &&h
p.push(5)

--cytest: error
--CompileError: `p` can not outlive `h`.
--
--@MainPath():22:9:
--    p = &&h
--        ^~~
--
