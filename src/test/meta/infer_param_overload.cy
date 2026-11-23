use test

-- An overload that needs no inference is picked when it matches the arguments exactly, in either
-- declaration order. Otherwise the overload that infers its template parameters is used.
fn conv(x %T, f fn(T) -> %U) -> str:
    return 'generic %{f(x)}'
fn conv(x int, f fn(int) -> int) -> str:
    return 'exact %{f(x)}'

fn conv2(x int, f fn(int) -> int) -> str:
    return 'exact %{f(x)}'
fn conv2(x %T, f fn(T) -> %U) -> str:
    return 'generic %{f(x)}'

fn toi(x int) -> int:
    return x + 1
fn tos(x int) -> str:
    return 's%{x}'
fn name(x float) -> str:
    return 'v%{x}'

test.eq('exact 2', conv(1, toi))
test.eq('generic s1', conv(1, tos))
test.eq('generic v1.5', conv(1.5, name))
test.eq('exact 2', conv(1, |x| x + 1))
test.eq('generic 3.0', conv(1.5, |x| x * 2))

test.eq('exact 2', conv2(1, toi))
test.eq('generic s1', conv2(1, tos))
test.eq('generic v1.5', conv2(1.5, name))
test.eq('exact 2', conv2(1, |x| x + 1))
test.eq('generic 3.0', conv2(1.5, |x| x * 2))

-- Overloads by the number of parameters.
fn pick(f fn(%T) -> %U, x T) -> U:
    return f(x)
fn pick(x int) -> int:
    return x
test.eq(7, pick(7))
test.eq(8, pick(toi, 7))
test.eq('v0.5', pick(name, 0.5))

--cytest: pass