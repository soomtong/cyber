use test

-- A closure does not match an overload that takes a function pointer: the call goes on to the overload that
-- takes a `Func`.
fn m(x %T, f fn(T) -> %U) -> str:
    return 'pointer'
fn m(x float, f Func[fn(float) -> float]) -> str:
    return 'func %{f(x)}'

fn n(x %T, f fn(T) -> T) -> str:
    return 'pointer'
fn n(x float, f Func[fn(float) -> float]) -> str:
    return 'func %{f(x)}'

k := ^1
test.eq('func 1.0', m(1, |x| if (k.* > 0) x else -x))
test.eq('pointer', m(1, |x| x + 1))
test.eq('func 1.0', n(1, |x| if (k.* > 0) x else -x))
test.eq('pointer', n(1, |x| x + 1))

--cytest: pass
