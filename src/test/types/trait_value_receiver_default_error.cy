type Sized trait:
    fn size() -> int

    fn double() -> int:
        return self.size() * 2

type Unit:
    with Sized
    n int

fn (Unit) size() -> int:
    return self.n

print(Unit{n=4}.double())

--cytest: error
--CompileError: `Unit` can not be used as `Dyn[Sized]`. The method `size` takes the receiver as `Unit`, but a call through `Dyn` passes a shared borrow `&Unit`. Declare the method as `fn (&Unit) size(...)`.
--
--@MainPath():4:5:
--    fn double() -> int:
--    ^~~~~~~~~~~~~~~~~~~
--
