use test

-- An inferred lambda as the argument: its parameters are typed from the template parameters that the
-- arguments before it bound, and the template parameter in the return type is the type of its body.
fn map(items []%T, f fn(T) -> %U) -> []U:
    out := []U{}
    for items |it|:
        out += f(it)
    return out

ints := map([]int{1, 2}, |x| x + 1)
test.eq(3, ints[1])
strs := map([]float{1, 2}, |x| 'v%{x}')
test.eq('v1.0', strs[0])
bools := map([]int{1, 2}, |x| x > 1)
test.eq(true, bools[1])

-- The result is the argument of another call.
test.eq('3!', map(map([]int{1, 2}, |x| x + 1), |x| '%{x}!')[1])

-- A nested type in the return type.
fn nest(x %T, f fn(T) -> []%U) -> []U:
    return f(x)
test.eq('a', nest(3, |x| []str{'a'})[0])

fn opt(x %T, f fn(T) -> ?%U) -> ?U:
    return f(x)
test.eq(4, opt(3, |x| ?int(x + 1)).?)

-- Two parameters, the second from an argument of its own.
fn zip(a %A, b %B, f fn(A, B) -> %C) -> C:
    return f(a, b)
test.eq(3.5, zip(1.5, 2, |x, y| x + float(y)))
test.eq('a1', zip('a', 1, |x, y| '%{x}%{y}'))

-- No parameters.
fn make(n int, f fn() -> %U) -> []U:
    out := []U{}
    for 0..n:
        out += f()
    return out
test.eq(2, make(2, |_| 'x').len())

-- A closure for a function union parameter.
fn call_union(x %T, f Func[fn(T) -> %U]) -> U:
    return f(x)

fn call_opaque(x %T, f &OpaqueFunc[fn(T) -> %U]) -> U:
    return f.*(x)

k := ^10
test.eq(12, call_union(2, |x| x + k.*))
test.eq('2:10', call_union(2, |x| '%{x}:%{k.*}'))
test.eq(12, call_opaque(2, |x| x + k.*))
test.eq(3, call_union(2, |x| x + 1))
local := 5
b := &local
test.eq(7, call_opaque(2, |x| x + b.*))

--cytest: pass