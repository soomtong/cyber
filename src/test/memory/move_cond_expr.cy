use test

-- An `if` expression in the first condition of an `if` statement, or in the left operand of `and` · `or`, moves a
-- local of the block of the statement like a statement of that block: the local is dead after the statement, and a
-- loop around the block does not see the move. See `docs/decisions/project_last_use.md`.

global log str = ''

type R struct:
    with NoCopy
    id int

fn (&R) @deinit():
    log += 'd%{self.id} '

fn take(r R) -> int:
    log += 't%{r.id} '
    return r.id

fn chk(exp str):
    test.eq(exp, log)
    log = ''

fn forCond():
    for 0..2 |i|:
        x := R{id=i}
        if (if (i == 0) take(x) else 0) == 1:
            log += 'y '
        log += 'z '

fn whileCond():
    i := 0
    while i < 2:
        x := R{id=i}
        if (if (i == 0) take(x) else 7) == 7:
            log += 'y '
        log += 'z '
        i += 1

fn andLeft():
    for 0..2 |i|:
        x := R{id=i}
        if (if (i == 0) take(x) else 0) == 0 and i == 0:
            log += 'y '
        log += 'z '

fn orLeft():
    for 0..2 |i|:
        x := R{id=i}
        b := (if (i == 1) take(x) else 0) == 1 or i == 5
        log += 'b%{b} '

-- A local of a block further out is a move of the enclosing branch.
fn outerLocal(n int):
    a := R{id=5}
    if n < 2:
        if (if (n == 0) take(a) else 0) == 5:
            log += 'y '
        log += 'in '
    log += 'end '

fn unwrapCond(n int):
    x := R{id=n}
    if (if (n == 0) ?int(take(x)) else none) |v|:
        log += 'v%{v} '
    log += 'end '

forCond()
chk('t0 d0 z d1 z ')
whileCond()
chk('t0 d0 z d1 y z ')
andLeft()
chk('t0 d0 y z d1 z ')
orLeft()
chk('d0 bfalse t1 d1 btrue ')
outerLocal(0)
chk('t5 d5 y in end ')
outerLocal(1)
chk('d5 in end ')
outerLocal(2)
chk('d5 end ')
unwrapCond(0)
chk('t0 d0 v0 end ')
unwrapCond(1)
chk('d1 end ')

--cytest: pass
