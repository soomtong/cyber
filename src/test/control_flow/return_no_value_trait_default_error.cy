-- A default method of a trait is checked like any other function.
type Shape trait:
    fn area() -> int
    fn twice() -> int:
        if self.area() > 3:
            return
        return self.area() * 2

type Box:
    with Shape
    x int

fn (&Box) area() -> int:
    return self.x

b := Box{x=5}
print(b.twice())

--cytest: error
--CompileError: Expected a return value of type `int`. A `return` without a value is for a function that returns `void` or `!void`.
--
--@MainPath():6:13:
--            return
--            ^~~~~~
--
