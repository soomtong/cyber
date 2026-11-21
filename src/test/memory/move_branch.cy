use test

-- A branch of an `if` statement can move a local of an outer block. The other branches that reach the end, and the
-- implicit `else`, destruct it at their end. The local is dead after the statement.
-- See `docs/decisions/project_last_use.md`.

global log str = ''

type R struct:
    with NoCopy
    id int

fn (&R) @deinit():
    log += 'd%{self.id} '

fn take(r R):
    log += 't%{r.id} '

fn run(flag int):
    -- No `else`.
    a := R{id=1}
    if flag == 1:
        take(a)
    log += '| '

    -- With `else`.
    b := R{id=2}
    if flag == 1:
        take(b)
    else:
        log += 'e '
    log += '| '

    -- `else cond:` and `else`.
    c := R{id=3}
    if flag == 1:
        log += 'one '
    else flag == 2:
        take(c)
    else:
        take(c)
    log += '| '

    -- Nested.
    d := R{id=4}
    if flag == 1:
        if flag == 1:
            take(d)
    log += '| '

    -- A branch that returns does not reach the join.
    e := R{id=5}
    if flag == 2:
        take(e)
        return
    log += 'end '

run(1)
test.eq('t1 d1 | t2 d2 | one d3 | t4 d4 | end d5 ', log)
log = ''
run(2)
test.eq('d1 | e d2 | t3 d3 | d4 | t5 d5 ', log)

--cytest: pass
