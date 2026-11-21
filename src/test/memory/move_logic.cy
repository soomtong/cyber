use test

-- The left operand of `and` and `or` always runs, so it moves an outer local like a statement of the block around the
-- expression. The right operand does not (`move_and_error.cy`). See `docs/decisions/project_last_use.md`.

global log str = ''

type R struct:
    with NoCopy
    id int

fn (&R) @deinit():
    log += 'd%{self.id} '

fn take(r R) -> bool:
    log += 't%{r.id} '
    return r.id > 0

fn takeN(r R) -> int:
    log += 't%{r.id} '
    return r.id

fn run(flag bool):
    a := R{id=1}
    b := R{id=2}
    ok := take(a) and flag
    ok2 := take(b) or flag
    log += 'end%{ok}%{ok2} '

-- Nested on the left: `(x and y) and z`, and inside the condition of an `if` statement, `while` exits.
fn run2(flag bool):
    a := R{id=1}
    b := R{id=2}
    c := R{id=3}
    if take(a) and flag and flag:
        log += 'then '
        _ = take(b)
    else:
        log += 'else '
    v := if (takeN(c) > 0 or flag) 1 else 2
    log += 'end%{v} '

-- In a branch and a loop body that leaves.
fn run3(n int):
    a := R{id=1}
    for 0..3 |i|:
        if i == n:
            if take(a) and i > 5:
                log += 'x '
            break
    log += 'end '

run(true)
test.eq(log, 't1 d1 t2 d2 endtruetrue ')
log = ''
run(false)
test.eq(log, 't1 d1 t2 d2 endfalsetrue ')
log = ''
run2(true)
test.eq(log, 't1 d1 then t2 d2 t3 d3 end1 ')
log = ''
run2(false)
test.eq(log, 't1 d1 else d2 t3 d3 end1 ')
log = ''
run3(1)
test.eq(log, 't1 d1 end ')
log = ''
run3(7)
test.eq(log, 'd1 end ')

--cytest: pass