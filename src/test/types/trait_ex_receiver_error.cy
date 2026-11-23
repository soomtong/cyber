type Grow trait:
    fn push(x int)

type Box:
    with Grow
    xs []int

fn (&&Box) push(x int):
    self.xs += x

b := Box{xs={1, 2, 3}}
var d &Dyn[Grow] = &b
first := &b.xs[0]
d.push(4)
print(first.*)

--cytest: error
--CompileError: `Box` does not implement `fn push(Grow, int) -> void` from `Grow`. The method `push` takes an exclusive borrow `&&Box`, but a trait method takes a shared borrow `&Box`. Keep what `push` changes behind a reference `^T`, or call `push` on `Box` without the trait.
--
--@MainPath():5:10:
--    with Grow
--         ^~~~
--@MainPath():4:1:
--type Box:
--^~~~~~~~~
--
