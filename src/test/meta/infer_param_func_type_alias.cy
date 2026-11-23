use test

-- A template parameter is inferred through a type alias template of a function type.
type MapFn[A Any, B Any] = fn(A) -> B
type Bin[A Any] = fn(A, A) -> A
type ListFn[A Any, B Any] = MapFn[A, []B]

fn map(items []%T, f MapFn[T, %U]) -> []U:
    out := []U{}
    for items |it|:
        out += f(it)
    return out

fn name(x float) -> str:
    return 'v%{x}'
test.eq('v2.0', map([]float{1, 2}, name)[1])
test.eq(true, map([]int{1, 2}, |x| x > 1)[1])

-- Only infer parameters.
fn apply(f MapFn[%T, %U], x T) -> U:
    return f(x)
test.eq('v1.5', apply(name, 1.5))

-- The alias uses its parameter more than once.
fn fold(f Bin[%T], a T, b T) -> T:
    return f(a, b)

fn add(a int, b int) -> int:
    return a + b
test.eq(3, fold(add, 1, 2))

-- An alias of an alias.
fn flat(x %T, f ListFn[T, %U]) -> []U:
    return f(x)

fn rep(x int) -> []int:
    return []int{x, x}
test.eq(4, flat(4, rep)[1])
test.eq('a', flat(4, |x| []str{'a'})[0])

-- An argument of the alias that is a type form of its own.
fn heads(items []%T, f MapFn[[]T, %U]) -> U:
    return f(items)

fn first(x []int) -> int:
    return x[0]
test.eq(7, heads([]int{7, 8}, first))

-- The alias as the argument of a function union.
fn call_union(x %T, f Func[MapFn[T, %U]]) -> U:
    return f(x)
k := ^10
test.eq(12, call_union(2, |x| x + k.*))

--cytest: pass