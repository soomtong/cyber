use test

-- A fiber that is suspended inside a `@deinit` can be cancelled. The rest of the value is destructed: its fields,
-- the other elements of its collection, and the object of a `^T` that held it. The `@deinit` itself does not run
-- further, like any other function that the fiber is in.
global log int = 0
global stop bool = true

type Inner:
    id int
fn (&Inner) @deinit():
    log += 1

type E:
    s str
    in Inner
fn (&E) @deinit():
    log += 10
    if stop:
        stop = false
        deep(3)
fn deep(k int):
    if k == 0:
        suspend
        return
    deep(k - 1)

fn mk(name str) -> E:
    return E{s=name + '-long-padding-padding-padding', in=Inner{id=1}}

fn check(fb Fiber, want int):
    log = 0
    stop = true
    test.eq(fb.resume(), .suspended)
    test.eq(fb.cancel(), true)
    test.eq(fb.status(), .done)
    test.eq(log, want)

-- At the end of the block. The fields of the value are destructed after the cancel.
fn at_block_end():
    e := mk('a')
check(fiber at_block_end(), 11)

-- The release of the last reference.
type R:
    e E
fn at_release():
    r := ^R{e=mk('a')}
check(fiber at_release(), 11)

-- In the middle of a statement: the list literal drops the temporary values it copied. The other temporary and
-- the list's elements are destructed after the cancel.
fn in_list():
    xs := []E{mk('a'), mk('b')}
check(fiber in_list(), 44)

-- A generator that is dropped: its frame is destructed by `Generator.end`.
generator fn gen() -> int:
    e := mk('a')
    yield 1
    yield 2
fn at_gen_end():
    g := gen()
    _ = g.next()
check(fiber at_gen_end(), 11)

--cytest: pass
