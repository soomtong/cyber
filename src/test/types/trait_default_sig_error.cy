-- A method with the parameters of a default method takes its place. With another return type it does not
-- implement the trait.
type Shape trait:
    fn describe() -> str:
        return 'shape'

type Circle:
    with Shape

fn (&Circle) describe() -> int:
    return 1

--cytest: error
--CompileError: `Circle` does not implement `fn describe(Shape) -> str` from `Shape`.
--
--@MainPath():8:10:
--    with Shape
--         ^~~~~
--@MainPath():7:1:
--type Circle:
--^~~~~~~~~~~
--
