use test

-- Overload resolution prefers the candidate whose parameter types match without implicit conversions,
-- regardless of declaration order (F-21). Before the fix the first declared candidate that fit won,
-- so `show(n)` with `n int` went to the `float` overload when it was declared first.
fn show(x float) -> str:
    return 'float'
fn show(x int) -> str:
    return 'int'

n := 3
test.eq('int', show(n))
f := 2.5
test.eq('float', show(f))

-- Literals: an integer literal is exact for `int`, a float literal for `float`.
test.eq('int', show(4))
test.eq('float', show(2.5))

-- With only a `float` overload, `int` still converts implicitly (second pass).
fn half(x float) -> float:
    return x / 2.0
test.eq(2.0, half(n + 1))
test.eq(2.0, half(4))

-- Same with the `int` overload declared first.
fn show2(x int) -> str:
    return 'int'
fn show2(x float) -> str:
    return 'float'
test.eq('int', show2(n))
test.eq('float', show2(f))
test.eq('int', show2(4))
test.eq('float', show2(2.5))

-- Mixed arity and types.
fn pick(a int, b float) -> str:
    return 'int,float'
fn pick(a float, b int) -> str:
    return 'float,int'
test.eq('int,float', pick(n, f))
test.eq('float,int', pick(f, n))
test.eq('int,float', pick(1, 2.0))
test.eq('float,int', pick(1.0, 2))

-- Methods.
type Box:
    v int
fn (&Box) add(x float) -> str:
    return 'float'
fn (&Box) add(x int) -> str:
    return 'int'
b := Box{v=1}
test.eq('int', b.add(n))
test.eq('float', b.add(f))
test.eq('int', b.add(7))

--cytest: pass
