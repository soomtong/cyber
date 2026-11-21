use test

-- The body of a `scope` block moves outer locals. A failing `!` of the body leaves with the ones that the body moved
-- so far and destructs the ones that only a later `!` leaves moved. See `docs/decisions/project_last_use.md`.

global log str = ''

type R struct:
    with NoCopy
    id int

fn (&R) @deinit():
    log += 'd%{self.id} '

fn take(r R):
    log += 't%{r.id} '

fn may(ok bool) -> !int:
    if !ok:
        return error.Bad
    return 1

-- The body moves outer locals; a failing `!` leaves with the ones moved so far.
fn run(n int) -> !void:
    a := R{id=1}
    b := R{id=2}
    c := R{id=3}
    scope |s|:
        k := R{id=9}
        _ = may(n != 0)!
        take(a)
        _ = may(n != 1)!
        take(b)
        _ = may(n != 2)!
    log += 'end '

-- Inside a `try`: the handler sees the moved ones dead.
fn run2(n int):
    a := R{id=1}
    b := R{id=2}
    try:
        scope |s|:
            _ = may(n != 0)!
            take(a)
            _ = may(n != 1)!
        log += 'after '
    else:
        log += 'else '
        if n == 0:
            take(b)
    log += 'end '

-- In a loop: break after the move.
fn run3(n int) -> !void:
    a := R{id=1}
    for 0..3 |i|:
        scope |s|:
            if i == n:
                take(a)
                break
    log += 'end '

-- A fiber fails: the error leaves at the end of the block, after the body moved `a`.
fn bad(n int) -> !void:
    suspend
    if n == 1:
        return error.Bad

fn run4(n int):
    a := R{id=1}
    b := R{id=2}
    try:
        scope |s|:
            s.start(bad, {n})
            take(a)
        log += 'after '
    else:
        log += 'else '
    log += 'end '

fn check(n int) -> str:
    log = ''
    try:
        run(n)!
    else:
        log += 'err '
    return log

test.eq(check(0), 'd9 d2 d1 d3 err ')
test.eq(check(1), 't1 d1 d9 d2 d3 err ')
test.eq(check(2), 't1 d1 t2 d2 d9 d3 err ')
test.eq(check(3), 't1 d1 t2 d2 d9 end d3 ')

log = ''
run2(0)
test.eq(log, 'd1 else t2 d2 end ')
log = ''
run2(1)
test.eq(log, 't1 d1 else d2 end ')
log = ''
run2(2)
test.eq(log, 't1 d1 after d2 end ')

log = ''
run3(1)!
test.eq(log, 't1 d1 end ')
log = ''
run3(3)!
test.eq(log, 'd1 end ')

log = ''
run4(0)
test.eq(log, 't1 d1 after end d2 ')
log = ''
run4(1)
test.eq(log, 't1 d1 else end d2 ')

--cytest: pass