use t 'test'

type Vec2:
    x float
    y float
    name str

fn (&Vec2) `*`(s float) -> Vec2:
    return {x=self.x * s, y=self.y * s, name=self.name}

-- The left operand is a number: the operator comes from the module of the right type.
fn `*`(s float, v Vec2) -> Vec2:
    return {x=s * v.x, y=s * v.y, name=v.name}

-- A borrow parameter takes the right operand like a receiver.
fn `+`(n int, v &Vec2) -> Vec2:
    return {x=v.x + float(n), y=v.y + float(n), name=v.name}

v := Vec2{x=1, y=2, name='a' + 'b'}
t.eq((v * 2.0).x, 2.0)
t.eq((2.0 * v).y, 4.0)
f := 0.5
t.eq((f * v).y, 1.0)
-- The literal takes the type of the parameter.
t.eq((2 * v).x, 2.0)
t.eq((3 + v).y, 5.0)
n := 4
t.eq((n + v).y, 6.0)
-- The operands are not moved.
t.eq(v.name, 'ab')

-- A type without the operator method: the module-level function takes the left operand too.
type Cents:
    n int

fn `/`(c Cents, d int) -> Cents:
    return {n=c.n / d}

fn `-`(a Cents, b Cents) -> Cents:
    return {n=a.n - b.n}

c := Cents{n=10}
t.eq((c / 2).n, 5)
t.eq((c - Cents{n=1}).n, 9)

-- An operator function with an infer parameter.
type Box[T Any]:
    x T

fn `*`(s %T, b Box[T]) -> Box[T]:
    return {x=s * b.x}

t.eq((2 * Box[int]{x=3}).x, 6)
t.eq((2.5 * Box[float]{x=2}).x, 5.0)

--cytest: pass