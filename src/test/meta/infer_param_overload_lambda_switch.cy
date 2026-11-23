use test

-- A case of a `switch` expression that does not have the result type of an overload is a mismatch of that
-- overload, like a branch of an `if` expression: the call goes on to the next one.
fn pick(x int, f fn(int) -> str) -> str:
    return 'str %{f(x)}'
fn pick(x int, f fn(int) -> int) -> str:
    return 'int %{f(x)}'
fn pick(x int, f fn(int) -> ?float) -> str:
    return 'float %{f(x).?}'

fn ap(x int, f fn(int) -> int) -> int:
    return f(x)

-- Every case fits the first overload.
r := pick(1, |x|):
    return switch x:
        case 1 => 'one'
        else => 'other'
test.eq('str one', r)

-- No case fits the first overload.
r = pick(1, |x|):
    return switch x:
        case 1 => x + 10
        else => 0
test.eq('int 11', r)
r = pick(2, |x|):
    return switch x:
        case 1 => 1.5
        else => 2.5
test.eq('float 2.5', r)

-- Only the last case does not fit.
r = pick(2, |x|):
    return switch x:
        case 1 => 1
        case 2 => 2
        else => 2.5
test.eq('float 2.0', r)
r = pick(3, |x|):
    return switch x:
        case 1 => 1
        case 2 => 2
        else => 2.5
test.eq('float 2.5', r)

-- The initializer of a local with the type of the first case.
r = pick(1, |x|):
    v := switch x:
        case 1 => x + 10
        else => 0
    return v
test.eq('int 11', r)

-- Locals before the `switch` expression, and a lambda in a case that is dropped with the body.
r = pick(5, |x|):
    a := 10
    b := 20
    return switch x:
        case 1 => a
        else => ap(x, |y| y + 20) + b
test.eq('int 45', r)
r = pick(5, |x|):
    a := 'a'
    return switch x:
        case 1 => a
        else => 's%{ap(x, |y| y + 20)}'
test.eq('str s25', r)

-- An `if` expression in a case.
r = pick(5, |x|):
    return switch x:
        case 1 => 1
        else => if (x > 3) 2.5 else 3.5
test.eq('float 2.5', r)

-- Other `return`s of the block.
r = pick(0, |x|):
    if x == 0:
        return 7
    return switch x:
        case 1 => 1
        else => 2
test.eq('int 7', r)
r = pick(0, |x|):
    if x == 0:
        return 'zero'
    return switch x:
        case 1 => 'one'
        else => 'other'
test.eq('str zero', r)

-- Closures.
fn pick_union(x int, f Func[fn(int) -> str]) -> str:
    return 'str %{f(x)}'
fn pick_union(x int, f Func[fn(int) -> int]) -> str:
    return 'int %{f(x)}'

k := ^10
r = pick_union(1, |x|):
    return switch x:
        case 1 => x + k.*
        else => 0
test.eq('int 11', r)
r = pick_union(2, |x|):
    return switch x:
        case 1 => 'one'
        else => 's%{x + k.*}'
test.eq('str s12', r)
test.eq(10, k.*)

-- Methods.
type Num:
    n int
fn (&Num) with(f fn(int) -> str) -> str:
    return 'str %{f(self.n)}'
fn (&Num) with(f fn(int) -> int) -> str:
    return 'int %{f(self.n)}'

num := Num{n=3}
r = num.with(|x|):
    return switch x:
        case 3 => x + 1
        else => 0
test.eq('int 4', r)
r = num.with(|x|):
    return switch x:
        case 3 => 's%{x}'
        else => 'none'
test.eq('str s3', r)

-- In a function with locals.
fn in_func(x int) -> str:
    a := 1
    b := 2
    r := pick(x, |y|):
        return switch y:
            case 1 => 1
            else => 2.5
    return '%{a + b} ' + r
test.eq('3 float 1.0', in_func(1))
test.eq('3 float 2.5', in_func(2))

--cytest: pass
