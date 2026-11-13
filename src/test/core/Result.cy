use test

-- Initialize value.
res := as[!int] 123
test.eq(123, res!)

-- Initialize value, implicitly.
res = 234
test.eq(234, res!)

-- Initialize error.
res = as[!int] error.Invalid
test.eq(error.Invalid, res.unwrap_error())

-- Initialize error, implicitly.
res = error.Invalid
test.eq(error.Invalid, res.unwrap_error())

-- Unwrap value.
fn ok() -> !str:
    res := Result[int](123)
    return str(res!)
test.eq('123', ok()!)

-- Unwrap error and propagate.
fn fail() -> !str:
    res := Result[int](error.Invalid)
    return str(res!)
test.eq(error.Invalid, fail().unwrap_error())

-- !else unwraps value.
res = 123
test.eq(123, res !else 0)

-- !else defaults.
res = error.Invalid
test.eq(0, res !else 0)

-- !else block unwraps value.
res = 123
act := res !else:
    panic('Unexpected')
test.eq(res, act)

-- !else block branches to error case.
fn foo() -> int:
    res := Result[int](error.Invalid)
    return res !else:
        return 0
test.eq(0, foo())

-- !else block branches and captures error.
fn foo2() -> int:
    res := Result[int](error.Invalid)
    return res !else |err|:
        test.eq(error.Invalid, err)
        return 0
test.eq(0, foo2())

-- A result with a managed payload is copied, as a value and as an error.
fn str_ok() -> !str:
    return 'abc'
fn str_err() -> !str:
    return error.Invalid
s := str_ok()
s_copy := s
test.eq('abc', s_copy!)
test.eq('abc', s!)
e := str_err()
e_copy := e
test.eq(error.Invalid, e_copy.unwrap_error())
test.eq(error.Invalid, e.unwrap_error())
fn ints_ok() -> ![]int:
    return {1, 2}
ints := ints_ok()
ints_copy := ints
test.eq(2, ints_copy!.len())
test.eq(2, ints![1])

-- Generic code can print a `!T`: the value or the error. Script code has to unwrap it first.
fn print_str(x %T) -> str:
    return '%{x}'
fn maybe(ok bool) -> !int:
    if ok:
        return 7
    return error.Bad
test.eq('7', print_str(maybe(true)))
test.eq('error.Bad', print_str(maybe(false)))
test.eq('7', to_print_string(maybe(true)!))

--cytest: pass