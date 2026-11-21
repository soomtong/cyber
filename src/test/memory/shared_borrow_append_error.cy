-- A shared borrow gives no exclusive borrow of what is behind it: `s` can point into the buffer that `append` frees.
type Foo:
    xs []int

fn (&Foo) grow():
    for 0..100 |i|:
        self.xs.append(i)

f := Foo{xs={1, 2, 3}}
s := &f.xs[0]
f.grow()
print(s.*)

--cytest: error
--CompileError: Cannot borrow exclusively through a shared borrow. Declare the borrow as `&&T`.
--
--@MainPath():7:9:
--        self.xs.append(i)
--        ^~~~~~~
--