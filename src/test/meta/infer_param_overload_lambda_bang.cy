use test

-- A `!` in the body of an inferred lambda that the result type of an overload can not pass on is a mismatch of
-- that overload: the call goes on to the next one.
fn conv(x str, f fn(str) -> str) -> str:
    return 'str %{f(x)}'
fn conv(x %T, f fn(T) -> %U) -> U:
    return f(x)

test.eq(12, conv('12', |x| int.parse(x)!)!)
test.eq(13, conv('12', |x| int.parse(x)! + 1)!)
test.eq('str s12', conv('12', |x| 's%{x}'))
res := conv('zz', |x| int.parse(x)!)
test.eq(-1, res !else -1)

-- Overloads without template parameters.
fn pick(x str, f fn(str) -> int) -> str:
    return 'int %{f(x)}'
fn pick(x str, f fn(str) -> !int) -> str:
    return 'result %{f(x) !else -1}'

test.eq('int 2', pick('12', |x| x.len()))
test.eq('result 12', pick('12', |x| int.parse(x)!))
test.eq('result -1', pick('zz', |x| int.parse(x)!))
test.eq('result 13', pick('12', |x| if (x.len() > 0) int.parse(x)! + 1 else 0))

-- Lambdas with a block.
r := pick('12', |x|):
    v := int.parse(x)!
    return v * 2
test.eq('result 24', r)

r = pick('12', |x|):
    return x.len() * 2
test.eq('int 4', r)

-- An overload that infers template parameters and declares the result type, tried first.
fn conv2(x %T, f fn(T) -> int) -> str:
    return 'int %{f(x)}'
fn conv2(x float, f fn(float) -> !int) -> str:
    return 'result %{f(x) !else -1}'

test.eq('int 2', conv2(1, |x| x + 1))
test.eq('result 7', conv2(1, |x| int.parse('7')!))

--cytest: pass
