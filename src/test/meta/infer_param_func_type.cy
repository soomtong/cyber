use test

-- A template parameter that is declared in the function type of a parameter is inferred from the function
-- type of the argument.
fn map(items []%T, f fn(T) -> %U) -> []U:
    out := []U{}
    for items |it|:
        out += f(it)
    return out

fn name(x float) -> str:
    return 'v%{x}'

names := map([]float{1, 2}, name)
test.eq(2, names.len())
test.eq('v1.0', names[0])
test.eq('v2.0', names[1])

-- A lambda with declared types is a function like any other.
strs := map([]int{1, 2}, fn(x int) -> str:
    return 'n%{x}'
)
test.eq('n2', strs[1])
doubled := map([]int{1, 2}, fn(x int) => x * 2)
test.eq(4, doubled[1])

-- A nested type in the return type.
fn nest(x %T, f fn(T) -> []%U) -> []U:
    return f(x)

fn rep(x int) -> []int:
    return []int{x, x}
test.eq(2, nest(3, rep).len())
test.eq(3, nest(3, rep)[1])

fn opt(x %T, f fn(T) -> ?%U) -> ?U:
    return f(x)

fn positive(x int) -> ?int:
    if x > 0:
        return x
    return none
test.eq(5, opt(5, positive).?)
test.eq(true, opt(-5, positive) == none)

-- Every parameter type and the return type, with the function before the arguments that use the parameters.
fn call2(f fn(%A, %B) -> %C, a A, b B) -> C:
    return f(a, b)

fn join(a str, b int) -> float:
    return float(b) + 0.5
test.eq(1.5, call2(join, 'a', 1))

fn rmap(f fn(%T) -> %U, items []T) -> []U:
    out := []U{}
    for items |it|:
        out += f(it)
    return out
test.eq('v2.0', rmap(name, []float{1, 2})[1])
test.eq(3, rmap(fn(x int) => x + 1, []int{1, 2})[1])

-- Only infer parameters, and only in a parameter type of the function.
fn arg_of(f fn(%T) -> int, x T) -> int:
    return f(x)

fn inc(x int) -> int:
    return x + 1
test.eq(8, arg_of(inc, 7))

-- A function type without a return type.
global seen int = 0
fn each(items []%T, f fn(T)):
    for items |it|:
        f(it)
fn see(x int):
    seen += x
each([]int{1, 2, 3}, see)
test.eq(6, seen)

-- A function union parameter takes a function or a closure.
fn call_union(x %T, f Func[fn(T) -> %U]) -> U:
    return f(x)

fn call_opaque(x %T, f &OpaqueFunc[fn(T) -> %U]) -> U:
    return f.*(x)

test.eq('v2.0', call_union(2.0, name))
test.eq('v2.0', call_opaque(2.0, name))
k := ^10
var closure Func[fn(int) -> int] = |x| x + k.*
test.eq(12, call_union(2, closure))
test.eq(12, call_opaque(2, closure))

-- The inferred parameter picks the variant: the same template with another function is another function.
fn len_of(x str) -> int:
    return x.len()
lens := map([]str{'a', 'bcd'}, len_of)
test.eq(3, lens[1])

--cytest: pass