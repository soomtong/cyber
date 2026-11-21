use test

-- An assignment gives a moved local a value again. The right side can move the local (`a = next(a)`), from a loop
-- body or a branch too: the local is alive when the statement ends. A moved local has no value to destruct.
-- See `docs/decisions/project_last_use.md` "이동한 지역에 다시 대입".

global log str = ''

type R struct:
    with NoCopy
    id int

fn (&R) @deinit():
    log += 'd%{self.id} '

fn next(r R) -> R:
    return R{id=r.id + 1}

fn take(r R):
    log += 't%{r.id} '

fn maybe(r R, ok bool) -> !R:
    if !ok:
        return error.Nope
    return R{id=r.id + 10}

fn pick(r R, n int) -> R:
    return R{id=r.id + n}

fn pick(r R, s str) -> R:
    return R{id=r.id + s.len()}

type M struct:
    name str
    xs   []int

fn grow(m M) -> M:
    return M{name=m.name + '!', xs=m.xs.appended(1)}

fn run(flag int) -> !void:
    -- Moved by the right side, in the block of the local.
    a := R{id=1}
    a = next(a)
    log += 'a%{a.id} | '

    -- Moved before the statement.
    b := R{id=10}
    take(b)
    b = R{id=11}
    log += 'b%{b.id} | '

    -- In a loop body, a local of an outer block.
    c := R{id=20}
    for 0..3:
        c = next(c)
    log += 'c%{c.id} | '

    -- In a branch.
    d := R{id=30}
    if flag == 1:
        d = next(d)
    else:
        log += 'else '
    log += 'd%{d.id} | '

    -- Moved in a branch: dead after the statement, then assigned.
    e := R{id=40}
    if flag == 1:
        take(e)
    e = R{id=41}
    log += 'e%{e.id} | '

    -- `!`: the function returns with the local moved.
    f := R{id=50}
    f = maybe(f, flag == 1)!
    log += 'f%{f.id} | '

fn run2():
    -- `g = g`.
    g := R{id=60}
    g = g
    log += 'g%{g.id} | '

    -- With `move`, also in a `while` body.
    h := R{id=70}
    h = next(move h)
    while h.id < 73:
        h = next(move h)
    log += 'h%{h.id} | '

    -- The second overload is matched after the first one moved the local.
    i := R{id=80}
    for 0..2:
        i = pick(i, 'xx')
    log += 'i%{i.id} | '

fn run3():
    -- An `!else` block that leaves the loop: the local is of the loop body.
    for 0..2 |n|:
        j := R{id=90}
        j = maybe(j, n < 1) !else:
            log += 'break '
            break
        log += 'j%{j.id} '

fn run4() -> !void:
    -- An `!else` block that returns: a local of an outer block is moved on that path.
    k := R{id=1}
    for 0..3 |n|:
        k = maybe(k, n < 1) !else:
            log += 'return '
            return
        log += 'k%{k.id} '

run(1)!
test.eq('d1 a2 | t10 d10 b11 | d20 d21 d22 c23 | d30 d31 | t40 d40 e41 | d50 f60 | d60 d41 d31 d23 d11 d2 ', log)
log = ''
try:
    run(2)!
else |err|:
    log += 'err '
test.eq('d1 a2 | t10 d10 b11 | d20 d21 d22 c23 | else d30 | d40 e41 | d50 d41 d30 d23 d11 d2 err ', log)
log = ''
run2()
test.eq('g60 | d70 d71 d72 h73 | d80 d82 i84 | d84 d73 d60 ', log)
log = ''
run3()
test.eq('d90 j100 d100 d90 break ', log)
log = ''
run4()!
test.eq('d1 k11 d11 return ', log)

-- A copyable struct with managed members through a loop.
m := M{name='m', xs=[]int{}}
for 0..3:
    m = grow(m)
test.eq('m!!!', m.name)
test.eq(3, m.xs.len())

--cytest: pass
