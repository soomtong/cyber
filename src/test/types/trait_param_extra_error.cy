type Shape trait:
    fn scale(k float) -> float

type Circle:
    with Shape
    r float

-- More parameters than the trait method. Before the fix this compiled and the extra argument was garbage.
fn (&Circle) scale(k float, j float) -> float:
    return k + j

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
