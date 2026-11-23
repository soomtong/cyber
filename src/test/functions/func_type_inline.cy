use test

fn double(x int) -> int:
    return x * 2

fn add(a, b int) -> int:
    return a + b

-- Function parameter. The `-> int` after `)` is the return type of `apply`.
fn apply(x int, f fn(int) -> int) -> int:
    return f(x)
test.eq(6, apply(3, double))
test.eq(4, apply(3, |x| x + 1))
test.eq(9, apply(3, fn(x int) -> int => x * 3))

-- No return type is `void`.
fn each(x int, f fn(int)):
    f(x)
fn run(f fn()):
    f()
fn record(x int):
    pass
each(7, record)
each(7, |x| test.eq(7, x))
run(|_| test.eq(1, 1))

-- Parameter names are optional and do not change the type.
fn apply2(f fn(a int, b int) -> int) -> int:
    return f(1, 2)
test.eq(3, apply2(add))

-- Return type. The function type takes everything to its right.
fn make() -> fn(int) -> int:
    return double
test.eq(8, make()(4))

-- Single line body after a function return type.
fn make_line() -> fn(int) -> int: return double
test.eq(8, make_line()(4))

fn make_void() -> fn(int):
    return record
make_void()(1)

-- A function type that returns a function type is right-associative.
fn curry() -> fn(int) -> fn(int) -> int:
    return |a| double
test.eq(10, curry()(1)(5))

fn curry_group(f fn(int) -> (fn(int) -> int)) -> int:
    return f(1)(6)
test.eq(12, curry_group(|a| double))

-- A prefix takes the whole function type.
fn opt(b bool) -> ?fn(int) -> int:
    if b:
        return double
    return none
test.eq(12, opt(true).?(6))
test.eq(true, opt(false) == none)

fn res(b bool) -> !fn(int) -> int:
    if b:
        return double
    return error.Nope
test.eq(14, res(true)!(7))

-- A function type that returns an option or an error union.
fn call_opt(f fn() -> ?int) -> int:
    return f().?
test.eq(6, call_opt(|_| 6))

fn call_res(f fn() -> !int) -> !int:
    return f()!
test.eq(7, call_res(|_| 7)!)

-- A parenthesized function type.
fn call_group(f ?(fn() -> int)) -> int:
    return f.?()
fn five() -> int:
    return 5
test.eq(5, call_group(five))

-- Struct fields.
type Box:
    f fn(int) -> int
    g fn(a int, b int) -> int
    h ?fn(int) -> int

-- Method parameter.
fn (&Box) call(k fn(int) -> int, x int) -> int:
    return k(self.f(x))

b := Box{f=double, g=|x, y| x + y, h=none}
test.eq(4, b.f(2))
test.eq(5, b.g(2, 3))
test.eq(20, b.call(double, 5))
test.eq(true, b.h == none)

-- Local variable.
var v fn(int) -> int = double
test.eq(20, v(10))
v = |x| x + 1
test.eq(11, v(10))

-- Global variable.
global gf fn(int) -> int = double
test.eq(16, gf(8))

-- Choice payload.
type Op enum:
    case unary fn(int) -> int
    case value int
op := Op.unary(double)
test.eq(18, op.!unary(9))

-- Type arguments.
fs := []fn(int) -> int{double, |x| x + 100}
test.eq(2, fs.len())
test.eq(101, fs[1](1))

var fs2 []fn(int) -> int = {double}
test.eq(42, fs2[0](21))

m := Map[str, fn(float, float) -> float]{}
m['add'] = |x, y| x + y
test.eq(3.5, m['add'](1.5, 2.0))

c := ^5
var fu Func[fn(int, int) -> int] = |x, y| x + y + c.*
test.eq(8, fu(1, 2))

fn pick(a, b int, less &OpaqueFunc[fn(int, int) -> bool]) -> int:
    if less.*(a, b):
        return a
    return b
test.eq(1, pick(1, 2, |x, y| x < y))
test.eq(1 + c.*, pick(1, 2, |x, y| x > y) + 4)

-- `as` target.
casted := as[fn(int) -> int] double
test.eq(4, casted(2))

-- Trait method signature.
type Visitor trait:
    fn visit(f fn(int) -> int) -> int
    fn maker() -> fn(int) -> int

type Sq:
    with Visitor
    n int

fn (&Sq) visit(f fn(int) -> int) -> int:
    return f(self.n)

fn (&Sq) maker() -> fn(int) -> int:
    return double

var s ^Dyn[Visitor] = ^Sq{n=9}
test.eq(18, s.visit(double))
test.eq(4, s.maker()(2))

-- Lambda parameter and lambda return type.
l := fn(a int, f fn(int) -> int) -> int:
    return f(a)
test.eq(22, l(11, double))

l2 := fn(f fn(int) -> int) -> fn(int) -> int => f
test.eq(24, l2(double)(12))

-- A lifted lambda is still a lambda.
lifted := ^fn(a int) -> int:
    return a + 1
test.eq(3, lifted.*(2))

--cytest: pass