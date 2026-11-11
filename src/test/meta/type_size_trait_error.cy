type Shape trait:
    fn area() -> float
y := type.size(Shape)

--cytest: error
--CompileError: The type `Shape` has no size.
--
--@MainPath():3:6:
--y := type.size(Shape)
--     ^~~~~~~~~~~~~~~~
--
