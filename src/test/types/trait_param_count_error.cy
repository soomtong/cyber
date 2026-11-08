type Shape trait:
    fn scale(k float, j float) -> float

type Circle:
    with Shape
    r float

-- Fewer parameters than the trait method. Before the fix this crashed the compiler.
fn (&Circle) scale(k float) -> float:
    return k

--cytest: error
--CompileError: `Circle` does not implement `fn scale(Shape, float, float) -> float` from `Shape`.
--
--@MainPath():5:10:
--    with Shape
--         ^~~~~
--@MainPath():4:1:
--type Circle:
--^~~~~~~~~~~~
--
