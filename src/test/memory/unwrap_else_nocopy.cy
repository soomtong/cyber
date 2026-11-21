use test

-- `?else` unwraps a `NoCopy` option that is a new value (a call).

global log str = ''

type R struct:
    with NoCopy
    id int

fn (&R) @deinit():
    log += 'd%{self.id} '

fn opt(ok bool) -> ?R:
    if !ok:
        return none
    return R{id=10}

fn step(r R, ok bool) -> ?R:
    if !ok:
        return none
    return R{id=r.id + 1}

fn run():
    for 0..3 |i|:
        b := opt(i < 1) ?else:
            log += 'none '
            continue
        log += 'b%{b.id} '
    d := opt(false) ?else R{id=7}
    log += 'd%{d.id} '
    e := opt(true) ?else R{id=8}
    log += 'e%{e.id} '
    a := R{id=1}
    for 0..3 |i|:
        a = step(a, i < 2) ?else:
            log += 'return '
            return
        log += 'a%{a.id} '

run()
test.eq('b10 d10 none none d7 e10 d1 a2 d2 a3 d3 return d10 d7 ', log)

--cytest: pass
