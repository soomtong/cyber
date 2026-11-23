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

-- More than one overload can take the literal: the first declared one is used.
fn first(x ?str) -> str:
    return 'str'
fn first(x ?int) -> str:
    return 'int'
test.eq('str', first(none))
test.eq('int', first(1))

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

--cytest: pass
