use test

-- A template parameter with a trait constraint is given a type that is declared further down. The traits of
-- that type are not known until it is resolved, which the check of the constraint now does.
type Num trait:
    fn val() -> int

type Wrap[T Num]:
    inner T

type Holder:
    w Wrap[I]

fn make(x int) -> Wrap[J]:
    return Wrap[J]{inner=J{v=x}}

type I:
    with Num
    v int

fn (&I) val() -> int:
    return self.v

type J:
    with Num
    v int

fn (&J) val() -> int:
    return self.v * 2

h := Holder{w=Wrap[I]{inner=I{v=3}}}
test.eq(3, h.w.inner.val())
test.eq(8, make(4).inner.val())

--cytest: pass
