type Sized trait:
    fn size() -> int

type Unit:
    with Sized
    n int

fn (^Unit) size() -> int:
    return self.n

u := Unit{n=4}
var d &Dyn[Sized] = &u
print(d.size())

--cytest: error
--CompileError: `Unit` can not be used as `Dyn[Sized]`. The method `size` takes the receiver as `^Unit`, but a call through `Dyn` passes a shared borrow `&Unit`. Declare the method as `fn (&Unit) size(...)`.
--
--@MainPath():12:21:
--var d &Dyn[Sized] = &u
--                    ^~
--
