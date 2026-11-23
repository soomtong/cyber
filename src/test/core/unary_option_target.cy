use t 'test'

-- A unary operator with a `?T` or `!T` target works on a `T`. The result is wrapped after.

fn isPos(x int) -> bool:
    return x > 0

fn notOpt(b bool) -> ?bool:
    return not b

fn notRes(b bool) -> !bool:
    return !b

fn notResOpt(b bool) -> !?bool:
    return !b

fn bitNotRes() -> !byte:
    return ~1

type Zero:
    x int

fn (&Zero) `!`() -> bool:
    return self.x == 0

-- `!` and `not` assigned to a `?bool`.
b := true
var a ?bool = !b
t.eq(a.?, false)
var a2 ?bool = not b
t.eq(a2.?, false)
var a3 ?bool = !!b
t.eq(a3.?, true)

-- Operand is a call.
t.eq(?bool(!isPos(1)).?, false)
var a4 ?bool = not isPos(-1)
t.eq(a4.?, true)

-- Return to `?bool`, `!bool` and `!?bool`.
t.eq(notOpt(true).?, false)
t.eq(notRes(false)!, true)
t.eq((notResOpt(true)!).?, false)

-- `!` overload.
z := Zero{x=0}
var a5 ?bool = !z
t.eq(a5.?, true)

-- `~` reads the literal as the child type of the option or result.
var c ?byte = ~1
t.eq(c.?, 0xfe)
t.eq(bitNotRes()!, 0xfe)
x := 3
var c2 ?int = ~x
t.eq(c2.?, -4)

-- `-` keeps working.
var d ?int = -x
t.eq(d.?, -3)
var d2 ?i8 = -128
t.eq(d2.?, -128)

--cytest: pass
