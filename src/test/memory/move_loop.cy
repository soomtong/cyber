use test

-- A loop body can move a local that is declared outside the loop where it then leaves the loop with `return` or
-- `break`, or assigns to the local again. After a `break` that moved it, the local is dead: the other ways out of the
-- loop destruct it. See `docs/decisions/project_last_use.md`.

global log str = ''

type R struct:
    with NoCopy
    id int

fn (&R) @deinit():
    log += 'd%{self.id} '

fn take(r R):
    log += 't%{r.id} '

fn takei(r R) -> int:
    return r.id

fn loopReturn(n int) -> int:
    a := R{id=1}
    xs := []int{0, 1, 2}
    for xs |x|:
        if x == n:
            return takei(a)
    log += 'end '
    return 0

fn rangeBreak(n int):
    a := R{id=1}
    for 0..3 |i|:
        if i == n:
            take(a)
            break
    log += 'after '

fn whileBreak(n int):
    a := R{id=1}
    i := 0
    while i < 3:
        if i == n:
            take(a)
            break
        if i == 2:
            break
        i += 1
    log += 'after '

fn infBreak(n int):
    a := R{id=1}
    i := 0
    while:
        tmp := R{id=7}
        if i == n:
            take(a)
            break
        i += 1
    log += 'after '

fn iterBreak(n int):
    a := R{id=1}
    xs := []int{0, 1, 2}
    for xs |x|:
        if x == n:
            take(a)
            break
    log += 'after '

fn twoLocals(n int):
    a := R{id=1}
    b := R{id=2}
    for 0..3 |i|:
        c := R{id=3}
        if i == n:
            take(a)
            take(b)
            break
        if i == 1:
            break
    log += 'after '

fn inBranch(n int):
    a := R{id=1}
    if n > 0:
        for 0..3 |i|:
            if i == n:
                take(a)
                break
        log += 'in '
    else:
        log += 'else '
    log += 'after '

fn nested(n int):
    a := R{id=1}
    for 0..3 |i|:
        for 0..3 |j|:
            if j == n:
                take(a)
                break
        break
    log += 'after '

fn inBegin():
    a := R{id=1}
    while:
        begin:
            take(a)
            break
    log += 'after '

fn refill():
    a := R{id=1}
    for 0..2 |i|:
        take(a)
        a = R{id=10 + i}
    log += 'after '

fn chk(exp str):
    test.eq(exp, log)
    log = ''

test.eq(1, loopReturn(1))
chk('d1 ')
test.eq(0, loopReturn(5))
chk('end d1 ')
rangeBreak(1)
chk('t1 d1 after ')
rangeBreak(5)
chk('d1 after ')
whileBreak(1)
chk('t1 d1 after ')
whileBreak(5)
chk('d1 after ')
infBreak(2)
chk('d7 d7 t1 d1 d7 after ')
iterBreak(1)
chk('t1 d1 after ')
iterBreak(5)
chk('d1 after ')
twoLocals(0)
chk('t1 d1 t2 d2 d3 after ')
twoLocals(5)
chk('d3 d3 d2 d1 after ')
inBranch(1)
chk('t1 d1 in after ')
inBranch(7)
chk('d1 in after ')
inBranch(0)
chk('else d1 after ')
nested(1)
chk('t1 d1 after ')
nested(5)
chk('d1 after ')
inBegin()
chk('t1 d1 after ')
refill()
chk('t1 d1 t10 d10 after d11 ')

-- At the top level.
g := R{id=5}
for 0..3 |i|:
    if i == 1:
        take(g)
        break
chk('t5 d5 ')

--cytest: pass