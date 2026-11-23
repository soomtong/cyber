use test

-- A `return` in the block of an inferred lambda that does not have the result type of an overload is a
-- mismatch of that overload: the call goes on to the next one.
fn pick(x int, f fn(int) -> str) -> str:
    return 'str %{f(x)}'
fn pick(x int, f fn(int) -> int) -> str:
    return 'int %{f(x)}'
fn pick(x int, f fn(int) -> ?float) -> str:
    return 'float %{f(x).?}'
fn pick(x int, f fn(int) -> void) -> str:
    f(x)
    return 'void'

fn ap(x int, f fn(int) -> int) -> int:
    return f(x)

r := pick(1, |x|):
    return x + 1
test.eq('int 2', r)

r = pick(1, |x|):
    return 's%{x}'
test.eq('str s1', r)

-- Every `return` is compared.
r = pick(1, |x|):
    if x > 5:
        return 3
    return x + 1
test.eq('int 2', r)

r = pick(1, |x|):
    if x > 5:
        return 'big'
    return 'small'
test.eq('str small', r)

-- Only the last `return` does not fit `int`.
r = pick(1, |x|):
    if x > 5:
        return 1
    return 2.5
test.eq('float 2.5', r)

-- Locals and a lambda inside the block are dropped with it.
r = pick(1, |x|):
    v := ap(x, |y| y * 2)
    if x > 5:
        return 0.5
    return if (v > 1) 2.5 else 3.5
test.eq('float 2.5', r)

-- A block without a `return` does not match an overload that needs a result.
global seen int = 0
r = pick(7, |x|):
    seen = x
test.eq('void', r)
test.eq(7, seen)

-- Closures.
fn pick_union(x int, f Func[fn(int) -> str]) -> str:
    return 'str %{f(x)}'
fn pick_union(x int, f Func[fn(int) -> int]) -> str:
    return 'int %{f(x)}'

k := ^10
r = pick_union(1, |x|):
    k.* += 1
    return x + k.*
test.eq('int 12', r)
test.eq(11, k.*)

-- Methods.
type Num:
    n int
fn (&Num) with(f fn(int) -> str) -> str:
    return 'str %{f(self.n)}'
fn (&Num) with(f fn(int) -> int) -> str:
    return 'int %{f(self.n)}'

num := Num{n=3}
r = num.with(|x|):
    return x * 2
test.eq('int 6', r)

--cytest: pass
