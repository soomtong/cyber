use test

-- A literal that takes its type from the parameter does not match an overload whose parameter it can not be
-- made for: the call goes on to the next overload.
type Color enum:
    case red
    case blue

type Shape enum:
    case circle
    case square

fn h(x int) -> str:
    return 'int'
fn h(x ?str) -> str:
    return 'option'

fn k(x int) -> str:
    return 'int'
fn k(c Color) -> str:
    return 'color %{c == .blue}'
fn k(s Shape) -> str:
    return 'shape'

test.eq('option', h(none))
test.eq('int', h(1))
test.eq('color false', k(.red))
test.eq('color true', k(.blue))
test.eq('shape', k(.square))
test.eq('int', k(3))

-- Two overloads can take `none`: converting it picks one (`first(none)` is ambiguous, see
-- `call_overload_ambiguous_error.cy`). A literal that only one of them can take needs no conversion.
fn first(x ?str) -> str:
    return 'str'
fn first(x ?int) -> str:
    return 'int'
test.eq('str', first(?str(none)))
test.eq('int', first(?int(none)))
test.eq('int', first(1))
-- A one-character literal is a string first.
test.eq('str', first('a'))
test.eq(1, 'abc'.index('b').?)

-- Overloads that only differ in number types are not ambiguous: an `i32` converts to both.
fn show(x float) -> str:
    return 'float'
fn show(x int) -> str:
    return 'int'
small := i32(3)
test.eq('float', show(small))

-- With other arguments.
fn two(x int, y float) -> str:
    return 'int'
fn two(x ?int, y float) -> str:
    return 'option'
fn two(c Color, y float) -> str:
    return 'color'
test.eq('option', two(none, 1))
test.eq('color', two(.red, 1))
test.eq('int', two(1, 1))

-- An inferred lambda does not match a parameter that is not a function type, or a function type with another
-- number of parameters.
fn each(x int) -> str:
    return 'int'
fn each(f fn(int) -> int) -> str:
    return 'one %{f(1)}'
fn each(f fn(int, int) -> int) -> str:
    return 'two %{f(1, 2)}'
test.eq('one 2', each(|a| a + 1))
test.eq('two 3', each(|a, b| a + b))
r := each(|a, b|):
    return a * b
test.eq('two 2', r)
r = each(|a|):
    return a
test.eq('one 1', r)

-- `|_|` is a lambda without parameters.
fn zero(f fn(int, int) -> int) -> str:
    return 'two'
fn zero(f fn() -> int) -> str:
    return 'zero %{f()}'
test.eq('zero 7', zero(|_| 7))

-- A template overload declared first is what the call picks: the two runtime overloads that a conversion would
-- match do not make it ambiguous.
fn pick(x %T) -> str:
    return 'template'
fn pick(x ?int) -> str:
    return 'option'
fn pick(x !int) -> str:
    return 'result'
n := 5
test.eq('template', pick(n))

--cytest: pass
