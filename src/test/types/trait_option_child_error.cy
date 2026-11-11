type Shape trait:
    fn area() -> float
var x ?Shape = none

--cytest: error
--CompileError: The type `Shape` has no size. It can not be the child of an option.
--
--@MainPath():3:7:
--var x ?Shape = none
--      ^~~~~~
--
