use test

-- `?else` unwraps a `NoCopy` option that is read from a variable: the option moves, like in `if o |v|:`.

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

fn run():
    o := opt(true)
    a := o ?else R{id=7}
    log += 'a%{a.id} '
    p := opt(false)
    b := p ?else R{id=8}
    log += 'b%{b.id} '
    q := opt(false)
    e := q ?else:
        log += 'ret '
        return
    log += 'e%{e.id} '

run()
test.eq('a10 b8 ret d8 d10 ', log)

--cytest: pass