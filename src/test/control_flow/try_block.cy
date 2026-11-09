use test

fn bar(fail bool) -> !int:
    if fail:
        return error.Fail
    return 7

-- Main block: failure jumps to else instead of panicking.
var got str = ''
try:
    a := bar(false)!
    b := bar(true)!
    got = 'unreachable %{a} %{b}'
else |err|:
    got = 'caught %{err}'
test.eq(got, 'caught error.Fail')

-- Success path skips the else block.
got = ''
try:
    a := bar(false)!
    got = 'ok %{a}'
else |err|:
    got = 'caught %{err}'
test.eq(got, 'ok 7')

-- Without capture.
got = ''
try:
    _ = bar(true)!
    got = 'no'
else:
    got = 'yes'
test.eq(got, 'yes')

-- Inside a function, the return type does not need to be a Result.
fn safe(fail bool) -> int:
    try:
        return bar(fail)!
    else |err|:
        return -1
test.eq(safe(true), -1)
test.eq(safe(false), 7)

-- Nested: innermost wins, else block `!` goes to the outer try.
got = ''
try:
    try:
        _ = bar(true)!
        got = 'no'
    else |inner|:
        got = 'inner %{inner}'
        _ = bar(true)!
        got = 'no2'
else |outer|:
    got = '%{got} outer %{outer}'
test.eq(got, 'inner error.Fail outer error.Fail')

-- Heap locals in the body are released on failure.
got = ''
try:
    s := 'abc'.repeat(10)
    _ = bar(true)!
    got = s
else |err|:
    got = 'released %{err}'
test.eq(got, 'released error.Fail')

-- `!` in a loop inside the body.
var count int = 0
try:
    for 0..5 |i|:
        count += 1
        _ = bar(i == 2)!
else:
    count += 100
test.eq(count, 103)

-- `!else` in the body keeps its own meaning.
got = ''
try:
    v := bar(true) !else 42
    got = 'default %{v}'
else:
    got = 'no'
test.eq(got, 'default 42')



-- A lambda inside the body is its own proc: its `!` follows the lambda's return type.
got = ''
try:
    f := fn (fail bool) -> !int:
        return bar(fail)! + 1
    got = 'lambda %{f(true).unwrap_error()} %{f(false)!}'
else |err|:
    got = 'outer %{err}'
test.eq(got, 'lambda error.Fail 8')

-- `!` in a while condition inside the body.
var n int = 0
try:
    while bar(n == 3)! == 7:
        n += 1
else:
    n += 100
test.eq(n, 103)

-- Inside a Result function: try handles the body, the rest still rethrows.
fn mixed(a bool, b bool) -> !int:
    var acc int = 0
    try:
        acc += bar(a)!
    else:
        acc += 50
    acc += bar(b)!
    return acc
test.eq(mixed(false, false).unwrap(), 14)
test.eq(mixed(true, false).unwrap(), 57)
test.eq(mixed(false, true).unwrap_error(), error.Fail)

-- Both body and handler return: the end is unreachable, so no missing return.
fn both(fail bool) -> int:
    try:
        return bar(fail)!
    else:
        return 0
test.eq(both(true), 0)

-- Small function that may be inlined.
fn tiny(fail bool) -> int:
    try:
        return bar(fail)! * 2
    else |e|:
        return 9
test.eq(tiny(false), 14)
test.eq(tiny(true), 9)

-- An owned Result local: the payload moves out on success.
try:
    r := bar(false)
    v := r!
    test.eq(v, 7)
else:
    test.fail()

-- Capture is a fresh local per else block.
try:
    _ = bar(true)!
else |err|:
    err2 := err
    test.eq(err2, error.Fail)

--cytest: pass
