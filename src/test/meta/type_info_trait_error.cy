type Shape trait:
    fn area() -> float
y := type.info(Shape)

--cytest: error
--CompileError: `type.info` does not support the trait `Shape`.
--
--@MainPath():3:6:
--y := type.info(Shape)
--     ^~~~~~~~~~~~~~~~
--
