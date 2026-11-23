use test

type IntFn = fn(int) -> int
type NamedFn = fn(value int) -> int

fn double(x int) -> int:
    return x * 2

fn by_alias(f IntFn) -> int:
    return f(1)

fn by_inline(f fn(int) -> int) -> int:
    return f(1)

-- A value of the alias type is a value of the inline type and the reverse.
var a IntFn = double
var i fn(int) -> int = a
a = i
test.eq(2, by_alias(i))
test.eq(2, by_inline(a))
test.eq(a, i)

var n NamedFn = i
i = n
test.eq(2, by_inline(n))

-- The same type, the same name.
test.eq('fn(int) -> int', type.name(IntFn))
test.eq('fn(int) -> int', type.name(fn(int) -> int))
test.eq('fn(int) -> int', type.name(fn(value int) -> int))
test.eq('?fn(int) -> int', type.name(?fn(int) -> int))
test.eq('fn(int) -> fn(int) -> int', type.name(fn(int) -> fn(int) -> int))
test.eq('fn(int) -> void', type.name(fn(int)))

-- Type arguments are the same type too.
var xs []IntFn = {double}
var ys []fn(int) -> int = xs
test.eq(4, ys[0](2))

var fu Func[IntFn] = double
var fu2 Func[fn(int) -> int] = fu
test.eq(6, fu2(3))

-- Overloads are told apart by the function type.
fn over(f fn(int) -> int) -> int:
    return 1
fn over(f fn(str) -> str) -> int:
    return 2
fn ident(s str) -> str:
    return s
test.eq(1, over(double))
test.eq(1, over(a))
test.eq(2, over(ident))

--cytest: pass