use test

-- Template overloads that differ only in the form of a parameter type with an infer parameter.
fn shape(x ?%T) -> str:
    return 'option'
fn shape(x []%T) -> str:
    return 'slice'
fn shape(x %T) -> str:
    return 'any'

var o ?int = 1
test.eq('option', shape(o))
test.eq('slice', shape({1, 2}))
test.eq('any', shape(3))

-- The form of a function type parameter.
fn map(x %T, f fn(T) -> ?%U) -> str:
    return 'option'
fn map(x %T, f fn(T) -> []%U) -> str:
    return 'slice'
fn some(x int) -> ?int:
    return x
fn list(x int) -> []int:
    return {x}
test.eq('option', map(1, some))
test.eq('slice', map(1, list))

-- A type argument goes to the overload that takes a `%T type`, whichever is declared first.
fn make(x str, n int) -> str:
    return 'str'
fn make(%T type, n int) -> str:
    return 'type'
test.eq('type', make(int, 1))
test.eq('str', make('a', 1))

-- A compile-time call goes on to the next overload too.
fn ct(x []%T) -> int:
    return 1
fn ct(x int) -> int:
    return 2
fn ct_type(%T type) -> int:
    return 1
fn ct_type(x int) -> int:
    return 2
const a = ct(3)
const b = ct_type(3)
const c = ct_type(int)
test.eq(2, a)
test.eq(2, b)
test.eq(1, c)

--cytest: pass
