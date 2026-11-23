use test

-- A parameter type uses an earlier template parameter and declares a new one.
type Pair[T Any, U Any]:
    a T
    b U

fn second(x %T, p Pair[T, %U]) -> U:
    return p.b

test.eq('x', second(1, Pair[int, str]{a=1, b='x'}))
test.eq(2.5, second('k', Pair[str, float]{a='k', b=2.5}))

fn value(key %K, m ^Map[K, %V]) -> V:
    return m[key]

m := ^Map[str, int]{a=1, b=2}
test.eq(2, value('b', m))

-- An option.
fn first(o ?%T) -> T:
    return o.?

var o ?int = 3
test.eq(3, first(o))

-- A compile-time call.
fn size(x %T, v [%N]T) -> int:
    return N + x

const n = size(1, [3]int{1, 2, 3})
test.eq(4, n)
test.eq(3, size(1, [2]int{1, 2}))

--cytest: pass