use test

-- A lambda with a block that captures a variable, as the argument of overloads.
fn run(x int, f Func[fn(int) -> int]) -> str:
    return 'int %{f(x)}'
fn run(x int, f Func[fn(int) -> void]) -> str:
    f(x)
    return 'void'
fn run(x int, f Func[fn(int) -> str]) -> str:
    return 'str %{f(x)}'

k := ^10

-- The block has no result: the overloads that need one do not match.
r := run(1, |x|):
    k.* = k.* + x
test.eq('void', r)
test.eq(11, k.*)

r = run(1, |x|):
    if x > 5:
        return
    k.* = k.* + x
test.eq('void', r)
test.eq(12, k.*)

r = run(1, |x|):
    return x + k.*
test.eq('int 13', r)

r = run(1, |x|):
    if x > 5:
        return 'big'
    return 'small %{k.*}'
test.eq('str small 12', r)

test.eq('int 13', run(1, |x| x + k.*))

--cytest: pass
