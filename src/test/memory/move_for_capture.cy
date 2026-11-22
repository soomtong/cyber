use test

-- The body of `for xs |i, x|:` can move the capture and the index. They end with the iteration: a path that moved one
-- and a path that did not (also one that ends with `continue`) destruct each value once.

global log str = ''

type S struct:
    id int

fn (&S) @deinit():
    log += 'd%{self.id} '

fn eat(s S) -> int:
    log += 'e%{s.id} '
    return s.id

fn chk(exp str):
    test.eq(exp, log)
    log = ''

fn len(s str) -> int:
    return s.len()

fn run():
    xs := []S{S{id=1}, S{id=2}, S{id=3}}
    log = ''
    -- Without a move: the capture and the hidden option of the iteration.
    for xs |x|:
        log += 'k%{x.id} '
    chk('k1 d1 d1 k2 d2 d2 k3 d3 d3 ')

    n := 0
    for xs |x|:
        n += eat(move x)
    test.eq(6, n)
    chk('e1 d1 d1 e2 d2 d2 e3 d3 d3 ')

    -- Moved on the path that ends with `continue`.
    for xs |x|:
        if x.id == 2:
            n += eat(move x)
            continue
        log += 'k%{x.id} '
    chk('k1 d1 d1 e2 d2 d2 k3 d3 d3 ')

    -- Moved on the path that reaches the end of the body.
    for xs |x|:
        if x.id == 2:
            continue
        n += eat(move x)
    chk('e1 d1 d1 d2 d2 e3 d3 d3 ')

    -- Moved in one branch.
    for xs |x|:
        if x.id == 2:
            n += eat(move x)
        log += '. '
    chk('d1 . d1 e2 d2 . d2 d3 . d3 ')

    for xs |i, x|:
        if x.id == 2:
            n += eat(move x)
            break
        n += move i
    chk('d1 d1 e2 d2 d2 ')

    -- From a nested block.
    for xs |x|:
        begin:
            y := move x
            log += 'y%{y.id} '
    chk('y1 d1 d1 y2 d2 d2 y3 d3 d3 ')

run()

ss := []str{'a', 'bb'}
m := 0
for ss |s|:
    m += len(move s)
test.eq(3, m)

--cytest: pass
