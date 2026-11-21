use test

-- The destructor that the join of an `if` statement puts at the end of a branch sees the locals as they are at the end
-- of that branch: not the locals of a later branch or of the `else` statements, not the local that the branch moved,
-- and not the ones that are destructed already. Before, the compiler panicked with 'expected mapping to IR local'
-- when the `else` statements declared a managed local.
-- See `docs/decisions/project_last_use.md`.

global log str = ''
-- The `@deinit` of the value with this id suspends.
global stop int = 0

type R struct:
    with NoCopy
    id int

fn (&R) @deinit():
    log += 'd%{self.id} '
    if stop == self.id:
        suspend
        log += 'resumed '

fn take(r R):
    log += 't%{r.id} '

fn key(flag int) -> str:
    return 'k' + str(flag)

-- Returns the log and clears it.
fn got() -> str:
    res := log
    log = ''
    return res

-- The `else` statements declare a local and move the outer one.
fn elseLocal(flag int):
    a := R{id=1}
    if flag == 1:
        log += 'one '
    else:
        x := R{id=10}
        take(a)
    log += 'end '
elseLocal(1)
test.eq(got(), 'one d1 end ')
elseLocal(2)
test.eq(got(), 't1 d1 d10 end ')

-- A string in the `else` statements.
fn elseStr(flag int):
    a := R{id=2}
    if flag == 1:
        log += 'one '
    else:
        x := 'abc' + str(flag)
        take(a)
        log += x + ' '
    log += 'end '
elseStr(1)
test.eq(got(), 'one d2 end ')
elseStr(2)
test.eq(got(), 't2 d2 abc2 end ')

-- Conditions with temps, the branches move different locals, no `else`.
fn chain(flag int):
    a := R{id=3}
    b := R{id=4}
    if key(flag) + 'x' == 'k1x':
        y := R{id=30}
        take(a)
    else key(flag) + 'y' == 'k2y':
        z := R{id=40}
        take(b)
    else key(flag) == 'k3':
        w := R{id=50}
        log += 'three '
    log += 'end '
chain(1)
test.eq(got(), 't3 d3 d30 d4 end ')
chain(2)
test.eq(got(), 't4 d4 d40 d3 end ')
chain(3)
test.eq(got(), 'three d50 d3 d4 end ')
chain(4)
test.eq(got(), 'd3 d4 end ')

-- The same with `else`.
fn chainElse(flag int):
    a := R{id=5}
    b := R{id=6}
    if key(flag) == 'k1':
        take(a)
    else key(flag) == 'k2':
        take(b)
        take(a)
    else:
        x := R{id=60}
        take(b)
    log += 'end '
chainElse(1)
test.eq(got(), 't5 d5 d6 end ')
chainElse(2)
test.eq(got(), 't6 d6 t5 d5 end ')
chainElse(3)
test.eq(got(), 't6 d6 d5 d60 end ')

-- Nested, with locals in every branch.
fn nested(flag int):
    a := R{id=7}
    if flag < 3:
        n := R{id=70}
        if flag == 1:
            m := R{id=71}
            take(a)
        else:
            k := R{id=72}
            log += 'in '
    else:
        x := R{id=73}
        log += 'out '
    log += 'end '
nested(1)
test.eq(got(), 't7 d7 d71 d70 end ')
nested(2)
test.eq(got(), 'in d7 d72 d70 end ')
nested(3)
test.eq(got(), 'out d7 d73 end ')

-- Branches that return or break do not reach the join.
fn leaves(flag int):
    a := R{id=8}
    for 0..1:
        b := R{id=9}
        if flag == 1:
            take(b)
            return
        else flag == 2:
            x := R{id=90}
            take(b)
            break
        else flag == 3:
            take(b)
        log += 'body '
    log += 'end '
leaves(1)
test.eq(got(), 't9 d9 d8 ')
leaves(2)
test.eq(got(), 't9 d9 d90 end d8 ')
leaves(3)
test.eq(got(), 't9 d9 body end d8 ')
leaves(4)
test.eq(got(), 'd9 body end d8 ')

-- A fiber that is cancelled inside a destructor of the join destructs each of the other locals once.
fn check(fb Fiber, stop_at int, want str, want_cancel str):
    log = ''
    stop = stop_at
    test.eq(fb.resume(), .suspended)
    test.eq(log, want)
    log = ''
    stop = 0
    test.eq(fb.cancel(), true)
    test.eq(fb.status(), .done)
    test.eq(log, want_cancel)

fn cancelChain(flag int):
    o := R{id=1}
    a := R{id=2}
    b := R{id=3}
    if key(flag) + 'x' == 'k1x':
        y := R{id=4}
        take(b)
    else key(flag) + 'y' == 'k2y':
        take(a)
    else:
        x := R{id=5}
        s := 'abc' + str(flag)
        take(a)
        take(b)
    log += 'end '
check(fiber cancelChain(1), 2, 't3 d3 d4 d2 ', 'd1 ')
check(fiber cancelChain(2), 3, 't2 d2 d3 ', 'd1 ')

-- A branch that destructs two locals.
fn cancelBoth(flag int):
    o := R{id=1}
    a := R{id=2}
    b := R{id=3}
    if flag == 1:
        log += 'one '
    else:
        x := R{id=5}
        take(a)
        take(b)
    log += 'end '
check(fiber cancelBoth(1), 2, 'one d2 ', 'd3 d1 ')
check(fiber cancelBoth(1), 3, 'one d2 d3 ', 'd1 ')

-- The implicit `else`.
fn cancelImplicit(flag int):
    o := R{id=1}
    a := R{id=2}
    b := R{id=3}
    if key(flag) + 'x' == 'k1x':
        take(a)
        take(b)
    log += 'end '
check(fiber cancelImplicit(2), 2, 'd2 ', 'd3 d1 ')
check(fiber cancelImplicit(2), 3, 'd2 d3 ', 'd1 ')

-- The last branch without `else`.
fn cancelLast(flag int):
    o := R{id=1}
    a := R{id=2}
    b := R{id=3}
    if key(flag) + 'x' == 'k1x':
        take(a)
    else key(flag) + 'y' == 'k2y':
        y := R{id=4}
        take(b)
    log += 'end '
check(fiber cancelLast(2), 2, 't3 d3 d4 d2 ', 'd1 ')
check(fiber cancelLast(1), 3, 't2 d2 d3 ', 'd1 ')
check(fiber cancelLast(3), 3, 'd2 d3 ', 'd1 ')

fn cancelNested(flag int):
    o := R{id=1}
    a := R{id=2}
    if flag < 3:
        n := R{id=6}
        if flag == 1:
            take(a)
        else:
            k := R{id=7}
            log += 'in '
    else:
        x := R{id=8}
        log += 'out '
    log += 'end '
check(fiber cancelNested(2), 2, 'in d2 ', 'd7 d6 d1 ')
check(fiber cancelNested(3), 2, 'out d2 ', 'd8 d1 ')

--cytest: pass
