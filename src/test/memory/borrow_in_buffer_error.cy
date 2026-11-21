-- A borrow can not be an element of a type that keeps its elements in a buffer: its lifetime is not checked there.
fn mk() -> []&int:
    x := 41
    return {&x}

xs := mk()
print(xs[0].*)

--cytest: error
--CompileError: `[]&int` keeps values of the borrow type `&int` in a buffer, where a borrow is not checked. Use an owned type, `^T` or a vector `[N]T`.
--
--@MainPath():2:12:
--fn mk() -> []&int:
--           ^~~~~~
--
