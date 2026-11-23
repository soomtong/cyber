-- Declares a trait with default overloads and uses a type of a module that imports this one for the trait.
use b './trait_default_cycle_b.cy'

type Shape trait:
    fn area() -> int:
        return self.area(1)
    fn area(scale int) -> int
    fn area(w int, h int) -> int:
        return self.area(w * h)

fn make(n int) -> b.Square:
    return b.Square{n=n}

fn total(s &Dyn[Shape]) -> int:
    return s.area() + s.area(2, 3)
