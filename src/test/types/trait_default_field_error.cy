type Shape trait:
    fn area() -> float
    fn describe() -> str:
        return 'radius %{self.radius}'

type Circle:
    with Shape
    radius float

fn (&Circle) area() -> float:
    return 3.14 * self.radius**2

print(Circle{radius=1}.describe())

--cytest: error
--CompileError: Field `radius` does not exist in `&Dyn[Shape]`. A default method of a trait can not access the fields of the implementing type, only the methods of the trait.
--
--@MainPath():4:31:
--        return 'radius %{self.radius}'
--                              ^~~~~~
--
