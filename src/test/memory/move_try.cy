use test

-- The body and the `else` block of a `try` statement move outer locals. A local that the body moved before a failing
-- `!` is dead in the `else` block, and a local that one way through the statement moved is dead after it: the other
-- ways destruct it. See `docs/decisions/project_last_use.md` "남은 다섯".

global log str = ''

type R struct:
    with NoCopy
    id int

fn (&R) @deinit():
    log += 'd%{self.id} '

fn take(r R):
    log += 't%{r.id} '

fn take2(r R, n int):
    log += 't%{r.id} '

fn may(ok bool) -> !int:
    if !ok:
        return error.Bad
    return 1

fn run(n int):
    a := R{id=1}
    b := R{id=2}
    c := R{id=3}
    try:
        k := R{id=9}
        _ = may(n != 0)!
        take(a)
        _ = may(n != 1)!
        take(b)
        _ = may(n != 2)!
    else |err|:
        log += 'else '
        if n == 2:
            take(c)
    log += 'end '

-- Each way moves another local.
fn run2(n int):
    a := R{id=1}
    b := R{id=2}
    try:
        _ = may(n != 0)!
        take(a)
    else:
        log += 'else '
        take(b)
    log += 'end '

-- In a loop: the body leaves the loop after the move, the `else` block returns.
fn run3(n int):
    a := R{id=1}
    for 0..3 |i|:
        try:
            _ = may(n != i)!
            if i == 1:
                take(a)
                break
        else:
            log += 'else '
            return
    log += 'end '

-- A `!` that fails in an argument after a moved argument, and a failing `!` of the `else` block of an inner `try`.
fn run4(n int):
    a := R{id=1}
    b := R{id=2}
    try:
        take2(a, may(n != 0)!)
        try:
            take2(b, may(n != 1)!)
        else:
            log += 'inner '
            _ = may(n != 1)!
    else |err|:
        log += 'else '
    log += 'end '

type Run = fn(int) -> void

fn check(exp str, f Run, n int):
    log = ''
    f(n)
    test.eq(exp, log)

check('d9 d2 d1 else d3 end ', run, 0)
check('t1 d1 d9 d2 else d3 end ', run, 1)
check('t1 d1 t2 d2 d9 else t3 d3 end ', run, 2)
check('t1 d1 t2 d2 d9 d3 end ', run, 3)
check('else t2 d2 d1 end ', run2, 0)
check('t1 d1 d2 end ', run2, 1)
check('else d1 ', run3, 0)
check('else d1 ', run3, 1)
check('t1 d1 end ', run3, 2)
check('t1 d1 end ', run3, 3)
check('d1 d2 else end ', run4, 0)
check('t1 d1 d2 inner else end ', run4, 1)
check('t1 d1 t2 d2 end ', run4, 2)

--cytest: pass
