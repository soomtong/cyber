use test

-- An inferred lambda for a function type whose return type declares a template parameter inside a type
-- that can not be expanded before the parameter is known. Each case also takes a function with a name.

type Pair[A Any, B Any]:
    a A
    b B

type Num trait:
    fn val() -> int

type I:
    with Num
    v int

fn (I) val() -> int:
    return self.v

type Wrap[T Num]:
    inner T

-- A template that looks at the type of its parameter.
fn conv(x %T, f fn(T) -> Map[%K, int]) -> Map[K, int]:
    return f(x)

fn conv_fn(x int) -> Map[str, int]:
    return Map[str, int]{a=x}
test.eq(2, conv(2, conv_fn)['a'])
test.eq(2, conv(2, |x| Map[str, int]{a=x})['a'])
test.eq(3, conv(3, |x| Map[str, int]{b=x})['b'])

-- A template with a constraint.
fn wrap(x %T, f fn(T) -> Wrap[%U]) -> U:
    return f(x).inner

fn wrap_fn(x int) -> Wrap[I]:
    return Wrap[I]{inner=I{v=x}}
test.eq(2, wrap(2, wrap_fn).v)
test.eq(2, wrap(2, |x| Wrap[I]{inner=I{v=x}}).v)

-- A value parameter.
fn vec(x %T, f fn(T) -> [%N]T) -> [N]T:
    return f(x)

fn vec_fn(x int) -> [3]int:
    return [3]int{x, x, x}
test.eq(2, vec(2, vec_fn)[2])
test.eq(2, vec(2, |x| [3]int{x, x, x})[2])

-- The template parameter is used again in the function type that declares it.
fn dup(x %T, f fn(T) -> Pair[%U, U]) -> U:
    return f(x).b

fn dup_fn(x int) -> Pair[str, str]:
    return Pair[str, str]{a='a', b='b'}
test.eq('b', dup(1, dup_fn))
test.eq('b', dup(1, |x| Pair[str, str]{a='a', b='b'}))
test.eq(2.0, dup(1, |x| Pair[float, float]{a=1.0, b=2.0}))

-- Nested in another type form.
fn opt_vec(x %T, f fn(T) -> ?[%N]T) -> T:
    return f(x).?[0]
test.eq(7, opt_vec(7, |x| ?[2]int([2]int{x, x})))

-- A closure for a function union parameter.
fn call_union(x %T, f Func[fn(T) -> Pair[%U, U]]) -> U:
    return f(x).b
k := ^10
test.eq(12, call_union(2, |x| Pair[int, int]{a=x, b=x + k.*}))

-- A type alias template of such a function type.
type MapOf[A Any, K Any] = fn(A) -> Map[K, int]

fn conv_alias(x %T, f MapOf[T, %K]) -> Map[K, int]:
    return f(x)
test.eq(2, conv_alias(2, conv_fn)['a'])
test.eq(2, conv_alias(2, |x| Map[str, int]{a=x})['a'])

-- A type alias template with a constraint.
type NumFn[A Any, B Num] = fn(A) -> B

fn num_alias(x %T, f NumFn[T, %U]) -> U:
    return f(x)
test.eq(5, num_alias(5, |x| I{v=x}).v)

--cytest: pass