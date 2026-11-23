use test

-- A branch of an `if` expression that does not have the result type of an overload is a mismatch of that
-- overload, like the whole body: the call goes on to the next one.
fn pick(x int, f fn(int) -> str) -> str:
    return 'str %{f(x)}'
fn pick(x int, f fn(int) -> int) -> str:
    return 'int %{f(x)}'
fn pick(x int, f fn(int) -> ?float) -> str:
    return 'float %{f(x).?}'
fn pick(x int, f fn(int) -> []int) -> str:
    return 'slice %{f(x).len()}'

fn ap(x int, f fn(int) -> int) -> int:
    return f(x)

test.eq('int 1', pick(1, |x| if (x > 0) x else 2))
test.eq('int 2', pick(-1, |x| if (x > 0) x else 2))
test.eq('str aa', pick(1, |x| if (x > 0) 'aa' else 'bb'))
test.eq('float 1.5', pick(1, |x| if (x > 0) 1.5 else 2.5))

-- Only the second branch does not fit.
test.eq('float 2.5', pick(-1, |x| if (x > 0) 1 else 2.5))

-- Nested branches and groups.
test.eq('int 3', pick(5, |x| if (x > 9) 1 else if (x > 7) 2 else 3))
test.eq('int 3', pick(5, |x| (if (x > 9) 1 else (if (x > 7) 2 else 3))))
test.eq('str cc', pick(5, |x| if (x > 9) 'aa' else if (x > 7) 'bb' else 'cc'))

-- A lambda inside a branch is dropped with the body.
test.eq('int 15', pick(5, |x| if (x > 9) 1 else ap(x, |y| y + 10)))
test.eq('str s15', pick(5, |x| if (x > 9) 'aa' else 's%{ap(x, |y| y + 10)}'))

-- A literal that takes its type from the result type.
test.eq('slice 3', pick(1, |x| {1, 2, 3}))
test.eq('slice 1', pick(1, |x| if (x > 9) {1, 2, 3} else {4}))

-- Closures.
fn pick_union(x int, f Func[fn(int) -> str]) -> str:
    return 'str %{f(x)}'
fn pick_union(x int, f Func[fn(int) -> int]) -> str:
    return 'int %{f(x)}'

k := ^10
test.eq('int 11', pick_union(1, |x| if (x > 0) x + k.* else 0))
test.eq('str s11', pick_union(1, |x| if (x > 0) 's%{x + k.*}' else 'none'))
test.eq(10, k.*)

-- Methods.
type Num:
    n int
fn (&Num) with(f fn(int) -> str) -> str:
    return 'str %{f(self.n)}'
fn (&Num) with(f fn(int) -> int) -> str:
    return 'int %{f(self.n)}'

num := Num{n=3}
test.eq('int 4', num.with(|x| if (x > 0) x + 1 else 0))
test.eq('str s3', num.with(|x| if (x > 0) 's%{x}' else 'none'))

--cytest: pass
