use test

-- An inferred lambda for a type alias template of a function type, where the template parameter that the
-- lambda binds is a value parameter of the alias. Each case also takes a function with a name.

type VecFn[const N int, T Any] = fn(T) -> [N]T

fn vec_fn(x int) -> [3]int:
    return [3]int{x, x, x}

fn vf(x %T, f VecFn[%N, T]) -> [N]T:
    return f(x)
test.eq(3, vf(4, vec_fn).len())
test.eq(3, vf(4, |x| [3]int{x, x, x}).len())
test.eq(4, vf(4, |x| [3]int{x, x, x})[2])
test.eq(2, vf(5, |x| [2]int{x, x}).len())
test.eq('a', vf('a', |x| [2]str{x, x})[1])

-- The value is a template parameter of the function.
fn vf_len(x %T, f VecFn[%N, T]) -> int:
    return N
test.eq(3, vf_len(4, vec_fn))
test.eq(3, vf_len(4, |x| [3]int{x, x, x}))
test.eq(5, vf_len(4, |x| [5]int{x, x, x, x, x}))

-- A later parameter uses the value.
fn vf_two(x %T, f VecFn[%N, T], g VecFn[N, T]) -> int:
    return f(x).len() + g(x).len()
test.eq(6, vf_two(4, |x| [3]int{x, x, x}, |x| [3]int{x, x, x}))

-- An alias of the alias.
type VecFn2[const M int, U Any] = VecFn[M, U]

fn vf_alias(x %T, f VecFn2[%N, T]) -> [N]T:
    return f(x)
test.eq(3, vf_alias(4, vec_fn).len())
test.eq(3, vf_alias(4, |x| [3]int{x, x, x}).len())

-- Nested in another type form.
type OptVecFn[const N int, T Any] = fn(T) -> ?[N]T

fn vf_opt(x %T, f OptVecFn[%N, T]) -> int:
    return f(x).?.len()
test.eq(3, vf_opt(4, |x| ?[3]int([3]int{x, x, x})))

-- A closure for a function union of the alias.
fn vf_union(x %T, f Func[VecFn[%N, T]]) -> [N]T:
    return f(x)
k := ^10
test.eq(10, vf_union(4, |x| [3]int{x, x, k.*})[2])

-- An alias of a function union.
type VecFunc[const N int, T Any] = Func[fn(T) -> [N]T]

fn vf_func(x %T, f VecFunc[%N, T]) -> [N]T:
    return f(x)
test.eq(10, vf_func(4, |x| [3]int{x, x, k.*})[2])

-- The value parameter of a type that is not an alias, inside the alias.
type Box[const N int]:
    v int

type BoxFn[const N int, T Any] = fn(T) -> Box[N]

fn box(x %T, f BoxFn[%N, T]) -> int:
    return N
test.eq(7, box(4, |x| Box[7]{v=x}))

-- A value parameter that is not an integer.
type Flag[const B bool]:
    v int

type FlagFn[const B bool, T Any] = fn(T) -> Flag[B]

fn flag(x %T, f FlagFn[%B, T]) -> bool:
    return B
test.eq(true, flag(4, |x| Flag[true]{v=x}))

-- An alias of the vector type in the function type.
type Arr[const N int, T Any] = [N]T

fn arr(x %T, f fn(T) -> Arr[%N, T]) -> int:
    return N
test.eq(3, arr(4, vec_fn))
test.eq(3, arr(4, |x| [3]int{x, x, x}))

--cytest: pass