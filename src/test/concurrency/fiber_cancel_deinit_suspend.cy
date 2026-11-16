use test

-- A `@deinit` that the cancel of a fiber calls can stop again, at a `suspend` or an `await`. It ends there like
-- the calls that the fiber was in, and the cancel goes on with the rest of the values. Before, this panicked with
-- `A fiber was suspended while it was cancelled.`
global log int = 0
-- The values stop in their `@deinit` only while a fiber is cancelled.
global stopping bool = false

type Inner:
    id int
fn (&Inner) @deinit():
    log += 1

-- Stops in its `@deinit` every time, also while it is cancelled.
type E:
    s str
    in Inner
fn (&E) @deinit():
    log += 10
    if stopping:
        deep(3)
    log += 1000
fn deep(k int):
    if k == 0:
        suspend
        return
    deep(k - 1)

-- Awaits in its `@deinit`.
type W:
    fut Future[int]
    in  Inner
fn (&W) @deinit():
    log += 10
    if stopping:
        _ = self.fut.await()
    log += 1000

-- Nothing completes it while the tests run.
r := FutureResolver.new(int)

fn mk(name str) -> E:
    return E{s=name + '-long-padding-padding-padding', in=Inner{id=1}}

fn check(fb Fiber, want int):
    test.eq(fb.resume(), .suspended)
    log = 0
    stopping = true
    test.eq(fb.cancel(), true)
    stopping = false
    test.eq(fb.status(), .done)
    test.eq(log, want)

fn two():
    a := mk('a')
    b := mk('b')
    suspend
check(fiber two(), 22)

fn one_await(f Future[int]):
    w := W{fut=f, in=Inner{id=1}}
    e := mk('a')
    suspend
check(fiber one_await(r.future()), 22)

fn in_list():
    xs := []E{mk('a'), mk('b')}
    suspend
check(fiber in_list(), 22)

type R:
    e E
fn at_release():
    r := ^R{e=mk('a')}
    suspend
check(fiber at_release(), 11)

generator fn gen() -> int:
    e := mk('a')
    yield 1
    yield 2
fn at_gen():
    g := gen()
    _ = g.next()
    suspend
check(fiber at_gen(), 11)

-- Dropping the fiber cancels it.
fn dropped():
    fb := fiber two()
    _ = fb.resume()
    log = 0
    stopping = true
dropped()
stopping = false
test.eq(log, 22)

-- A scope that fails cancels its other fiber, whose values stop in `@deinit`.
fn fails() -> !void:
    suspend
    return error.Oops
fn holds(f Future[int]) -> !void:
    a := mk('a')
    w := W{fut=f, in=Inner{id=1}}
    while:
        suspend
fn in_scope(f Future[int]) -> !void:
    scope |s|:
        s.start(holds, {f})
        s.start(fails, {})
log = 0
stopping = true
test.eq(in_scope(r.future()).unwrap_error(), error.Oops)
test.eq(log, 22)


-- The manual's example: each `@deinit` stops, and the fiber is still cancelled when it is destructed.
global num_res int = 0
type Res:
    id int
fn (&Res) @deinit():
    num_res += 1
    suspend
    num_res += 100
fn work():
    a := ^Res{id = 1}
    b := ^Res{id = 2}
fn start():
    f := fiber work()
    _ = f.resume()
start()
test.eq(num_res, 2)

-- A value in every frame of a deep call stops in its `@deinit`. The fiber is unwound once per stop, and each unwind
-- walks only the frames above the ones that already return to their pad.
global num_frames int = 0
type F:
    id int
fn (&F) @deinit():
    num_frames += 1
    suspend
    num_frames += 100000
fn nest(k int):
    e := F{id = k}
    if k == 0:
        suspend
        return
    nest(k - 1)
fn cancel_nest():
    f := fiber nest(2000)
    _ = f.resume()
    test.eq(f.cancel(), true)
cancel_nest()
test.eq(num_frames, 2001)

--cytest: pass