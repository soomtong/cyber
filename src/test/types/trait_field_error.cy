type Shape trait:
    fn area() -> float
type W:
    t Shape
w := W{t=1}

--cytest: error
--CompileError: The type `Shape` has no size. It can not be the type of a field.
--
--@MainPath():3:1:
--type W:
--^~~~~~~
--@MainPath():3:1:
--type W:
--^~~~~~~
--
