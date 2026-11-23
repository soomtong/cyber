type Shape trait:
    fn describe() -> str:
        return 'shape'

type Circle:
    with Shape

fn (&Circle) describe(prefix str) -> str:
    return prefix + 'circle'

--cytest: error
--CompileError: `Circle` does not implement `fn describe(Shape) -> str` from `Shape`.
--
--@MainPath():6:10:
--    with Shape
--         ^~~~~
--@MainPath():5:1:
--type Circle:
--^~~~~~~~~~~
--
