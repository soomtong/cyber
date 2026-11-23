use test

-- An infer parameter in a result type (`!%T`) is a template parameter like one in `?%T` or `[]%T`.

fn parse(s str) -> !int:
    return int.parse(s)

fn fail(s str) -> !float:
    return error.Bad

fn label(x int) -> !str:
    return 'v%{x}'

-- In the return type of a function type. `U` is bound from the function that can fail.
fn conv(x %T, f fn(T) -> !%U) -> !U:
    return f(x)

test.eq(12, conv('12', parse)!)
test.eq(error.Bad, conv('12', fail).unwrap_error())
test.eq(error.InvalidCharacter, conv('x', parse).unwrap_error())

-- From an inferred lambda. The type of its body is the result type.
test.eq(12, conv('12', |s| int.parse(s))!)
test.eq('v3', conv(3, |x| label(x))!)

-- As the type of a parameter.
fn un(x !%T) -> !T:
    return x

test.eq(1, un(int.parse('1'))!)
test.eq(1.5, un(float.parse('1.5'))!)
test.eq(error.Bad, un(fail('')).unwrap_error())

-- Nested with other type forms.
fn mk_slice() -> ![]str:
    return []str{'a'}

fn first(x ![]%T) -> !T:
    items := x!
    return items[0]

test.eq('a', first(mk_slice())!)

fn mk_opt() -> ?!int:
    return int.parse('4')

fn opt_res(x ?!%T) -> !T:
    return x.?

test.eq(4, opt_res(mk_opt())!)

-- In the target of a type alias template.
type Fallible[A Any, B Any] = fn(A) -> !B

fn conv_alias(x %T, f Fallible[T, %U]) -> !U:
    return f(x)

test.eq(7, conv_alias('7', parse)!)
test.eq(7, conv_alias('7', |s| int.parse(s))!)

-- A closure for a function union parameter.
fn add(s str, n int) -> !int:
    v := int.parse(s)!
    return v + n

fn call_union(x %T, f Func[fn(T) -> !%U]) -> !U:
    return f(x)

fn call_opaque(x %T, f &OpaqueFunc[fn(T) -> !%U]) -> !U:
    return f.*(x)

k := ^10
test.eq(17, call_union('7', |s| add(s, k.*))!)
test.eq(17, call_opaque('7', |s| add(s, k.*))!)
test.eq(7, call_union('7', parse)!)

--cytest: pass
