use t 'test'

-- A unary operator with a borrow receiver borrows its operand, as a method call does.
type Ix:
    v int

fn (&Ix) `-`() -> Ix:
    return Ix{v = -self.v}

fn (&Ix) `~`() -> Ix:
    return Ix{v = ~self.v}

fn (&&Ix) `!`() -> bool:
    self.v += 10
    return self.v > 0

type P:
    ix Ix

fn mk() -> Ix:
    return Ix{v = 5}

fn neg_field(p &P) -> int:
    return (-p.ix).v

x := Ix{v = 1}
y := -x
t.eq(y.v, -1)
t.eq(x.v, 1)
t.eq((~x).v, -2)

-- A temporary.
t.eq((-mk()).v, -5)

-- A field, and a field behind a borrow.
p := P{ix = Ix{v = 7}}
t.eq((-p.ix).v, -7)
t.eq(neg_field(&p), -7)

-- A borrow local.
b := &x
t.eq((-b).v, -1)
t.eq((~b).v, -2)

-- An exclusive borrow receiver changes the operand.
m := Ix{v = 3}
t.eq(!m, true)
t.eq(m.v, 13)
t.eq(not m, true)
t.eq(m.v, 23)
e := &&m
t.eq(!e, true)
t.eq(m.v, 33)

--cytest: pass
