use test

-- An overload that infers template parameters and declares the result type of its function parameter does not
-- match an inferred lambda with another result type: the call goes on to the next overload.
fn conv(x %T, f fn(T) -> str) -> str:
    return 'generic %{f(x)}'
fn conv(x float, f fn(float) -> float) -> str:
    return 'float %{f(x)}'
fn conv(x int, f fn(int) -> bool) -> str:
    return 'bool %{f(x)}'

fn twice(x int, f fn(int) -> int) -> int:
    return f(f(x))

test.eq('float 2.5', conv(1, |x| 2.5))
test.eq('generic ss', conv(1, |x| 'ss'))
test.eq('generic 1', conv(1, |x| '%{x}'))
test.eq('generic 1.5', conv(1.5, |x| '%{x}'))
test.eq('bool true', conv(1, |x| x > 0))
test.eq('float 3.0', conv(1.5, |x| x * 2))

-- Branches, and a lambda inside the body.
test.eq('float 2.5', conv(1, |x| if (x > 0) 2.5 else 1.5))
test.eq('bool true', conv(1, |x| twice(x, |y| y + 1) == 3))

-- Lambdas with a block.
r := conv(1, |x|):
    return x > 0
test.eq('bool true', r)

r = conv(1, |x|):
    if x > 5:
        return 'big'
    return 'small'
test.eq('generic small', r)

--cytest: pass
