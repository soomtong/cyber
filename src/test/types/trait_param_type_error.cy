type Shape trait:
    fn scale(k float) -> float

type Circle:
    with Shape
    r float

fn (&Circle) scale(k int) -> float:
    return k

--cytest: error
--CompileError: `Circle` does not implement `fn scale(Shape, float) -> float` from `Shape`.
--
--@MainPath():5:10:
--    with Shape
--         ^~~~~
--@MainPath():4:1:
--type Circle:
--^~~~~~~~~~~~
--
