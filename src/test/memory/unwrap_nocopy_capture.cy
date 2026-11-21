use test

-- `if opt |v|:` and `while opt |v|:` take a `NoCopy` payload out of the option: `v` owns it. An option that is read
-- from a variable is moved, so the variable is dead after the statement.

global log str = ''
global n int = 0

type R struct:
    with NoCopy
    id int

fn (&R) @deinit():
    log += 'd%{self.id} '

fn take(r R):
    log += 't%{r.id} '

fn mk(id int) -> ?R:
    if id == 0:
        return none
    return R{id=id}

fn next() -> ?R:
    n += 1
    if n > 2:
        return none
    return R{id=n}

fn f(id int):
    if mk(id) |v|:
        log += 'some%{v.id} '
    else:
        log += 'none '
    o := mk(id)
    if o |v|:
        take(v)
    else id == 0:
        log += 'zero '
    else:
        log += 'x '
    log += '| '

fn loop():
    while next() |v|:
        log += 'it%{v.id} '
    log += '| '

f(3)
test.eq('some3 d3 t3 d3 | ', log)
log = ''
f(0)
test.eq('none zero | ', log)
log = ''
loop()
test.eq('it1 d1 it2 d2 | ', log)
log = ''

--cytest: pass