use lib './lib.cy'

type Vec2:
    x float
    y float

fn (&Vec2) scale(by float) -> float:
    return self.x * by

fn add(first int, second int) -> int:
    total := first + second
    return total

v := Vec2{x = 1.0, y = 2.0}
n := add(1, 2)
print(lib.twice(n))
print(v.scale(2.0))
