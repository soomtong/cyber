type Shape trait:
    fn area() -> float
fn hash[K Any](key K) -> int:
    return 1
x := hash[Shape]

--cytest: error
--CompileError: Expected a value type for the parameter. `Shape` is a trait.
--
--@MainPath():3:20:
--fn hash[K Any](key K) -> int:
--                   ^
--@MainPath():5:6:
--x := hash[Shape]
--     ^~~~~~~~~~~
--
