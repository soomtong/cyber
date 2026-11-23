use test

-- An overload that infers template parameters does not match an argument whose type does not have the form
-- that its parameter declares: the call goes on to the next overload, also when the overload is declared first.
fn opt(x %T, f fn(T) -> ?%U) -> str:
    return 'option'
fn opt(x float, f fn(float) -> float) -> str:
    return 'float'

fn res(x %T, f fn(T) -> !%U) -> str:
    return 'result'
fn res(x float, f fn(float) -> float) -> str:
    return 'float'

fn sl(x %T, f fn(T) -> []%U) -> str:
    return 'slice'
fn sl(x float, f fn(float) -> float) -> str:
    return 'float'

fn mp(x %T, f fn(T) -> Map[%K, int]) -> str:
    return 'map'
fn mp(x float, f fn(float) -> float) -> str:
    return 'float'

fn half(x float) -> float:
    return x / 2
fn some(x int) -> ?int:
    return x
fn fail(x int) -> !int:
    return error.Bad
fn list(x int) -> []int:
    return {x}
fn table(x int) -> Map[str, int]:
    return Map[str, int]{}

-- An inferred lambda.
test.eq('float', opt(1, |x| 1.5))
test.eq('float', res(1, |x| x * 2))
test.eq('float', sl(1, |x| x))
test.eq('float', mp(1, |x| x * 2))

-- A named function, and a lambda that declares its types.
test.eq('float', opt(1, half))
test.eq('float', res(1, half))
test.eq('float', sl(1, half))
test.eq('float', mp(1, half))
test.eq('float', opt(1, fn(x float) -> float => x))

-- The form matches.
test.eq('option', opt(1, some))
test.eq('option', opt(1, fn(x int) -> ?int => x))
test.eq('result', res(1, fail))
test.eq('slice', sl(1, list))
test.eq('slice', sl(1, |x| []int{x}))
test.eq('map', mp(1, table))

-- A lambda inside the lambda is checked again for the next overload.
fn twice(x float, f fn(float) -> float) -> float:
    return f(f(x))
test.eq('float', opt(1, |x| twice(0.5, |y| y + 1)))

-- A lambda with a block: its result type is not inferred, so the overload that needs it does not match.
fn conv(x %T, f fn(T) -> %U) -> str:
    return 'generic'
fn conv(x float, f fn(float) -> float) -> str:
    return 'float'
r := conv(1, |x|):
    return x * 2
test.eq('float', r)
test.eq('generic', conv(1, |x| x * 2))

-- An argument that is not a lambda and does not have the type of its parameter.
fn pair(x %T, y str) -> str:
    return 'str'
fn pair(x int, y float) -> str:
    return 'float'
fn pair(x int, y ?bool) -> str:
    return 'bool'
test.eq('float', pair(1, 2))
test.eq('float', pair(1, 2.5))
test.eq('str', pair(1, 'a'))
test.eq('str', pair(1.5, 'a'))
test.eq('bool', pair(1, true))
test.eq('bool', pair(1, none))

-- The same when the overload that infers is declared last.
fn pair2(x float, y float) -> str:
    return 'float'
fn pair2(x %T, y str) -> str:
    return 'str'
test.eq('float', pair2(1, 2))
test.eq('str', pair2(1, 'a'))

-- Overloads that all infer.
fn both(x %T, y str) -> str:
    return 'str'
fn both(x %T, y bool) -> str:
    return 'bool'
fn both(x %T, y float) -> str:
    return 'float'
test.eq('str', both(1, 'a'))
test.eq('bool', both(1, true))
test.eq('float', both(1, 2))

--cytest: pass
