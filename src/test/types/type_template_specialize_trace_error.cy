-- An error in a method of a template type instance names where the type was specialized.
type Box[T Any]:
    v T

fn (&Box[]) area() -> int:
    return self.v.area()

b := Box[int]{v=1}
print(b.area())

--cytest: error
--CompileError: Can not find the symbol `area` in `int`.
--
--@MainPath():6:19:
--    return self.v.area()
--                  ^~~~
--While specializing `Box[int]` here:
--@MainPath():8:6:
--b := Box[int]{v=1}
--     ^~~~~~~~
--