use test

-- An overload candidate that does not match takes back the moves that its arguments made. An `if` expression
-- in an argument joins its branches before that: the moves that the block made earlier stay.

global log str = ''

type R struct:
    with NoCopy
    id int

fn (&R) @deinit():
    log += 'd%{self.id} '

fn take(r R):
    log += 't%{r.id} '

fn take1(r R) -> int:
    log += 't%{r.id} '
    return r.id

fn g(n int) -> !int:
    if n == 1:
        return error.Bad
    return n

fn f(a int, b str) -> int:
    return 1

fn f(a int, b int) -> int:
    return 2

fn f(a int, e int, b str) -> int:
    return 3

fn f(a int, e int, b int) -> int:
    return 4

-- The branch moved `y` before the call: the other path destructs it.
fn run(c bool):
    y := R{id=1}
    if c:
        take(y)
        x := R{id=2}
        k := f(if (c) take1(x) else 0, 5)
        log += 'k%{k} '
    log += 'end '

-- The argument moves the outer local itself.
fn run3(c bool, d bool):
    y := R{id=1}
    z := R{id=3}
    if c:
        take(z)
        k := f(if (d) take1(y) else 0, 5)
        log += 'k%{k} '
    log += 'end '

-- A loop body that leaves after the move.
fn run4(n int):
    y := R{id=1}
    for 0..3 |i|:
        x := R{id=10 + i}
        k := f(if (i == 0) take1(x) else 0, 5)
        log += 'k%{k} '
        if i == n:
            take(y)
            x2 := R{id=20 + i}
            k2 := f(if (i == 1) take1(x2) else 0, 5)
            log += 'k%{k2} '
            break
    log += 'end '

-- A failing `!` after the argument that moved.
fn run5(n int):
    y := R{id=1}
    for 0..2 |i|:
        x := R{id=10 + i}
        try:
            take(y)
            k := f(if (i == 0) take1(x) else 0, g(n)!, 5)
            log += 'k%{k} '
            break
        else |err|:
            log += 'failed '
            break
    log += 'end '

fn check(exp str):
    test.eq(exp, log)
    log = ''

run(true)
check('t1 d1 t2 d2 k2 end ')
run(false)
check('d1 end ')

run3(true, true)
check('t3 d3 t1 d1 k2 end ')
run3(true, false)
check('t3 d3 d1 k2 end ')
run3(false, false)
check('d3 d1 end ')

run4(1)
check('t10 d10 k2 d11 k2 t1 d1 t21 d21 k2 end ')
run4(5)
check('t10 d10 k2 d11 k2 d12 k2 d1 end ')

run5(0)
check('t1 d1 t10 d10 k4 end ')
run5(1)
check('t1 d1 t10 d10 failed end ')

--cytest: pass
