use test

-- The first condition of an `if` statement always runs: it moves a local like a statement of the block that the `if`
-- statement is in. The local is dead in every branch and after the statement.
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

fn take(r R) -> int:
    log += 't%{r.id} '
    return r.id

-- Returns the log and clears it.
fn got() -> str:
    res := log
    log = ''
    return res

-- A local of the same block, with branches that move another one.
fn cond(flag int):
    a := R{id=1}
    b := R{id=2}
    if take(a) == flag:
        log += 'one '
    else flag == 2:
        _ = take(b)
    else flag == 3:
        x := R{id=3}
        log += 'three '
    log += 'end '
cond(1)
test.eq(got(), 't1 d1 one d2 end ')
cond(2)
test.eq(got(), 't1 d1 t2 d2 end ')
cond(3)
test.eq(got(), 't1 d1 three d3 d2 end ')
cond(4)
test.eq(got(), 't1 d1 d2 end ')

-- The condition of a nested `if` statement moves a local of an outer block as a statement of the branch does.
fn nestedCond(flag int):
    a := R{id=4}
    b := R{id=5}
    if flag < 3:
        if take(a) + take(b) == 8 + flag:
            log += 'in '
        else:
            log += 'in-else '
    else flag == 3:
        _ = take(b)
    log += 'end '
nestedCond(1)
test.eq(got(), 't4 d4 t5 d5 in end ')
nestedCond(2)
test.eq(got(), 't4 d4 t5 d5 in-else end ')
nestedCond(3)
test.eq(got(), 't5 d5 d4 end ')
nestedCond(4)
test.eq(got(), 'd4 d5 end ')

-- In the `else` statements.
fn elseCond(flag int):
    a := R{id=6}
    if flag == 1:
        log += 'one '
    else:
        if take(a) == 6:
            log += 'six '
    log += 'end '
elseCond(1)
test.eq(got(), 'one d6 end ')
elseCond(2)
test.eq(got(), 't6 d6 six end ')

-- With `move`, and a branch that returns.
fn explicit(flag int):
    a := R{id=7}
    if take(move a) == flag:
        return
    log += 'end '
explicit(7)
test.eq(got(), 't7 d7 ')
explicit(1)
test.eq(got(), 't7 d7 end ')

-- In the main block.
log = ''
m := R{id=8}
if take(m) == 8:
    log += 'eight '
test.eq(log, 't8 d8 eight ')

-- A fiber that is cancelled inside a destructor of the join does not destruct the moved locals again.
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
check(fiber nestedCond(4), 4, 'd4 ', 'd5 ')
check(fiber nestedCond(3), 4, 't5 d5 d4 ', '')
check(fiber cond(4), 2, 't1 d1 d2 ', '')

--cytest: pass
