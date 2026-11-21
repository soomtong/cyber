use test

-- The `break` statements of a loop can follow different moves of outer locals: each one destructs the locals that
-- only the others moved, so the locals are dead after the loop on every path.
-- See `docs/decisions/project_last_use.md` "남은 다섯".

global log str = ''

type R struct:
    with NoCopy
    id int

fn (&R) @deinit():
    log += 'd%{self.id} '

fn take(r R):
    log += 't%{r.id} '

fn run(n int):
    a := R{id=1}
    b := R{id=2}
    c := R{id=3}
    for 0..3 |i|:
        k := R{id=9}
        if i == n:
            take(a)
            break
        if i + 10 == n:
            take(b)
            take(c)
            break
        if i + 20 == n:
            break
    log += 'end '

fn run2(n int):
    a := R{id=1}
    b := R{id=2}
    while:
        if n == 0:
            take(a)
            break
        take(b)
        break
    log += 'end '

fn check(exp str, n int):
    log = ''
    run(n)
    test.eq(exp, log)

check('d9 t1 d1 d9 d3 d2 end ', 1)
check('d9 t2 d2 t3 d3 d9 d1 end ', 11)
check('d9 d9 d3 d2 d1 end ', 21)
check('d9 d9 d9 d3 d2 d1 end ', 5)
log = ''
run2(0)
test.eq('t1 d1 d2 end ', log)
log = ''
run2(1)
test.eq('t2 d2 d1 end ', log)

--cytest: pass
