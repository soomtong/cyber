use test

-- An inferred lambda whose body does not have the result type of an overload is a mismatch of that
-- overload: the call goes on to the next one, like it does for a named function.
fn conv(x int, f fn(int) -> str) -> str:
    return 'exact %{f(x)}'
fn conv(x %T, f fn(T) -> %U) -> str:
    return 'generic %{f(x)}'

fn conv2(x %T, f fn(T) -> %U) -> str:
    return 'generic %{f(x)}'
fn conv2(x int, f fn(int) -> str) -> str:
    return 'exact %{f(x)}'

fn toi(x int) -> int:
    return x + 1

test.eq('generic 2', conv(1, toi))
test.eq('generic 2', conv(1, |x| x + 1))
test.eq('exact s1', conv(1, |x| 's%{x}'))
test.eq('generic 1', conv(1, |x| x))
test.eq('generic 3', conv(1, |x| (x * 3)))

test.eq('generic 2', conv2(1, toi))
test.eq('generic 2', conv2(1, |x| x + 1))
test.eq('exact s1', conv2(1, |x| 's%{x}'))

-- Overloads without template parameters. The body is fit to the result type as usual.
fn pick(x int, f fn(int) -> str) -> str:
    return 'str %{f(x)}'
fn pick(x int, f fn(int) -> int) -> str:
    return 'int %{f(x)}'
fn pick(x int, f fn(int) -> ?float) -> str:
    return 'float %{f(x).?}'

test.eq('int 2', pick(1, |x| x + 1))
test.eq('str s1', pick(1, |x| 's%{x}'))
test.eq('int 1', pick(1, |x| x))
test.eq('float 1.5', pick(1, |x| 1.5))

-- A lambda inside the body is dropped with it.
fn ap(x int, f fn(int) -> int) -> int:
    return f(x)
test.eq('int 11', pick(1, |x| ap(x, |y| y + 10)))
test.eq('str s11', pick(1, |x| 's%{ap(x, |y| y + 10)}'))

-- Closures.
fn pick_union(x int, f Func[fn(int) -> str]) -> str:
    return 'str %{f(x)}'
fn pick_union(x int, f Func[fn(int) -> int]) -> str:
    return 'int %{f(x)}'
fn pick_opaque(x int, f &OpaqueFunc[fn(int) -> str]) -> str:
    return 'str %{f.*(x)}'
fn pick_opaque(x int, f &OpaqueFunc[fn(int) -> int]) -> str:
    return 'int %{f.*(x)}'

k := ^10
test.eq('int 11', pick_union(1, |x| x + k.*))
test.eq('str s11', pick_union(1, |x| 's%{x + k.*}'))
test.eq('int 11', pick_opaque(1, |x| x + k.*))
test.eq('str s11', pick_opaque(1, |x| 's%{x + k.*}'))
test.eq(10, k.*)

-- Methods.
type Num:
    n int
fn (&Num) with(f fn(int) -> str) -> str:
    return 'str %{f(self.n)}'
fn (&Num) with(f fn(int) -> int) -> str:
    return 'int %{f(self.n)}'

num := Num{n=3}
test.eq('int 4', num.with(|x| x + 1))
test.eq('str s3', num.with(|x| 's%{x}'))

--cytest: pass
