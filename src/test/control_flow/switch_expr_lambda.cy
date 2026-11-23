use test

-- A `switch` expression in a lambda. The result local of the expression is a local of the lambda, and the
-- function around the lambda has locals of its own before it.

fn ap(x int, f fn(int) -> str) -> str:
    return f(x)
fn ap_int(x int, f fn(int) -> int) -> int:
    return f(x)
fn ap_union(x int, f Func[fn(int) -> str]) -> str:
    return f(x)

type Shape enum:
    case none
    case num int
    case name str

-- Returned from a block lambda.
f := fn(x int) -> str:
    return switch x:
        case 1 => 'one'
        case 2 => 'two'
        else => 'other'
test.eq('one', f(1))
test.eq('two', f(2))
test.eq('other', f(3))

-- A block lambda that is a call argument.
r := ap(2, |x|):
    return switch x:
        case 1 => 'one'
        case 2 => 'two'
        else => 'other'
test.eq('two', r)

-- The initializer of a local, after other locals of the lambda.
f2 := fn(x int) -> str:
    a := 'a'
    b := 'b'
    v := switch x:
        case 1 => a
        else => b
    return v + a
test.eq('aa', f2(1))
test.eq('ba', f2(2))

-- Assigned to a local.
f3 := fn(x int) -> int:
    v := 0
    v = switch x:
        case 1 => 10
        else => 20
    return v
test.eq(10, f3(1))
test.eq(20, f3(2))

-- The result is a call argument and a branch of an `if` expression.
f4 := fn(x int) -> str:
    v := switch x:
        case 1 => 'one'
        else => 'many'
    return ap(x, |y| 's%{y}') + (if (x > 0) v else 'none')
test.eq('s1one', f4(1))
test.eq('s5many', f4(5))
test.eq('s0none', f4(0))

-- An `if` expression and a lambda in a case.
f6 := fn(x int) -> str:
    return switch x:
        case 1 => if (x > 0) 'one' else 'never'
        else => if (x > 9) 'big' else 'small'
test.eq('one', f6(1))
test.eq('small', f6(5))
test.eq('big', f6(50))
f5 := fn(x int) -> str:
    return switch x:
        case 1 => ap(x, |y| 's%{y}')
        else => ap(x, |y| if (y == 2) 'two' else 'other')
test.eq('s1', f5(1))
test.eq('two', f5(2))
test.eq('other', f5(3))

-- Two `switch` expressions, and a `switch` statement around one.
f7 := fn(x int, y int) -> str:
    inner := switch y:
        case 1 => 'one one'
        else => 'one other'
    switch x:
        case 0:
            return switch y:
                case 1 => 'zero one'
                else => 'zero other'
        else:
            pass
    return switch x:
        case 1 => inner
        else => 'other'
test.eq('one one', f7(1, 1))
test.eq('one other', f7(1, 2))
test.eq('other', f7(2, 1))
test.eq('zero one', f7(0, 1))
test.eq('zero other', f7(0, 2))

-- A capture of a case is a local after the result local.
f8 := fn(s Shape) -> str:
    return switch s:
        case .num |n| => 'num %{n}'
        case .name |name| => 'name ' + name
        else => 'none'
test.eq('num 7', f8(Shape.num(7)))
test.eq('name abc', f8(Shape.name('abc')))
test.eq('none', f8(Shape.none))

f9 := fn(s Shape) -> int:
    k := 100
    v := switch s:
        case .num |n| => n + k
        else => -1
    return v + k
test.eq(207, f9(Shape.num(7)))
test.eq(99, f9(Shape.none))

-- A closure.
k := ^10
c := ap_union(1, |x|):
    return switch x + k.*:
        case 11 => 'eleven %{k.*}'
        else => 'other'
test.eq('eleven 10', c)
c2 := ap_union(2, |x|):
    v := switch x + k.*:
        case 11 => 'eleven'
        else => 'other %{k.*}'
    return 'x' + v
test.eq('xother 10', c2)
test.eq(10, k.*)

-- A lambda in a lambda.
f10 := fn(x int) -> str:
    a := 'outer'
    r := ap(x, |y|):
        b := 'inner'
        g := fn(z int) -> str:
            return switch z:
                case 1 => 'one'
                else => 'many'
        return switch y:
            case 1 => g(y)
            else => b + ' ' + g(y)
    return a + ' ' + r
test.eq('outer one', f10(1))
test.eq('outer inner many', f10(2))

-- A lambda in a function with locals.
fn in_func(x int) -> str:
    a := 1
    b := 2
    g := fn(y int) -> str:
        return switch y:
            case 3 => 'three'
            else => 'other'
    return g(x + a + b)
test.eq('three', in_func(0))
test.eq('other', in_func(1))

-- A lambda in a method.
type Num:
    n int
fn (&Num) name(base int) -> str:
    off := base + 1
    g := fn(y int) -> str:
        return switch y:
            case 4 => 'four'
            else => 'other'
    return g(self.n + off)
num := Num{n=3}
test.eq('four', num.name(0))
test.eq('other', num.name(1))

-- A lambda in a generator.
generator fn names(n int) -> str:
    g := fn(y int) -> str:
        return switch y:
            case 0 => 'zero'
            case 1 => 'one'
            else => 'many'
    for 0..n |i|:
        yield g(i)
gen := names(3)
test.eq('zero', gen.next().?)
test.eq('one', gen.next().?)
test.eq('many', gen.next().?)
test.eq(true, gen.next() == none)

-- A `switch` statement with `=>` cases.
f11 := fn(x int) -> int:
    v := 5
    v = switch x:
        case 1 => v + 1
        else => v - 1
    w := ap_int(v, |y|):
        return switch y:
            case 6 => 60
            else => 40
    return w
test.eq(60, f11(1))
test.eq(40, f11(2))

--cytest: pass
