type Shape trait:
    fn area() -> int

type Square:
    with Shape
    side int

fn (&Square) area() -> int:
    return self.side * scale

fn make() -> int:
    var shape ^Dyn[Shape] = ^Square{side=2}
    return shape.area()

global a int = make()
global scale int = 3

--cytest: error
--CompileError: The initializer of `a` can reach `area`, which accesses the global `scale`. `scale` is initialized after `a`.
--
--@MainPath():15:16:
--global a int = make()
--               ^~~~~~
--
