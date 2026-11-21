use test

-- Besides a branch of an `if` statement, a branch of an `if` unwrap statement, a case of a `switch` statement and a
-- `begin:` block can move a local of an outer block. A branch that moves a local and then assigns to it leaves it alive.
-- See `docs/decisions/project_last_use.md`.

global log str = ''

type R struct:
    with NoCopy
    id int

fn (&R) @deinit():
    log += 'd%{self.id} '

fn take(r R):
    log += 't%{r.id} '

type Shape enum:
    case circle
    case square
    case tri

fn sameBranch(flag bool):
    a := R{id=1}
    if flag:
        take(a)
        a = R{id=2}
    log += '| '

fn nestedAssign(flag bool):
    a := R{id=1}
    if flag:
        if flag:
            take(a)
        else:
            log += 'e '
        a = R{id=3}
    log += '| '

fn beginBlock():
    a := R{id=1}
    begin:
        take(a)
    log += '| '

fn beginInBranch(flag bool):
    a := R{id=1}
    if flag:
        begin:
            take(a)
    log += '| '

fn unwrapBranch(o ?int):
    a := R{id=1}
    if o |v|:
        take(a)
    else:
        log += 'none '
    log += '| '

fn unwrapNoElse(o ?int):
    a := R{id=1}
    if o |v|:
        take(a)
    log += '| '

fn unwrapElse(o ?int, flag bool):
    a := R{id=1}
    if o |v|:
        log += 'some '
    else flag:
        take(a)
    else:
        log += 'x '
    log += '| '

fn switchBranch(s Shape):
    a := R{id=1}
    switch s:
        case .circle:
            take(a)
        case .square:
            log += 'sq '
        else:
            b := R{id=9}
            log += 'else '
    log += '| '

fn switchAll(s Shape):
    a := R{id=1}
    switch s:
        case .circle:
            take(a)
        else:
            take(a)
    log += '| '

fn chk(exp str):
    test.eq(exp, log)
    log = ''

sameBranch(true)
chk('t1 d1 | d2 ')
sameBranch(false)
chk('| d1 ')
nestedAssign(true)
chk('t1 d1 | d3 ')
nestedAssign(false)
chk('| d1 ')
beginBlock()
chk('t1 d1 | ')
beginInBranch(true)
chk('t1 d1 | ')
beginInBranch(false)
chk('d1 | ')
unwrapBranch(1)
chk('t1 d1 | ')
unwrapBranch(none)
chk('none d1 | ')
unwrapNoElse(1)
chk('t1 d1 | ')
unwrapNoElse(none)
chk('d1 | ')
unwrapElse(1, true)
chk('some d1 | ')
unwrapElse(none, true)
chk('t1 d1 | ')
unwrapElse(none, false)
chk('x d1 | ')
switchBranch(.circle)
chk('t1 d1 | ')
switchBranch(.square)
chk('sq d1 | ')
switchBranch(.tri)
chk('else d9 d1 | ')
switchAll(.circle)
chk('t1 d1 | ')
switchAll(.tri)
chk('t1 d1 | ')

--cytest: pass