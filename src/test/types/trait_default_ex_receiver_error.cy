type Grow trait:
    fn push(x int)

    fn push_twice(x int):
        self.push(x)
        self.push(x)

type Box:
    with Grow
    xs []int

fn (&&Box) push(x int):
    self.xs += x

b := Box{xs={1, 2, 3}}
first := &b.xs[0]
b.push_twice(4)
print(first.*)

--cytest: error
--CompileError: `Box` does not implement `fn push(Grow, int) -> void` from `Grow`. The method `push` takes an exclusive borrow `&&Box`, but a trait method takes a shared borrow `&Box`. Keep what `push` changes behind a reference `^T`, or call `push` on `Box` without the trait.
--
--@MainPath():9:10:
--    with Grow
--         ^~~~
--@MainPath():8:1:
--type Box:
--^~~~~~~~~
--
