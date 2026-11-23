-- The trait of this type is declared in the module that imports this one.
use a './trait_default_cycle_a.cy'

type Square:
    with a.Shape
    n int

fn (&Square) area(scale int) -> int:
    return self.n * self.n * scale

fn as_dyn(n int) -> ^Dyn[a.Shape]:
    return ^Square{n=n}
