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

-- The other ways that a `@deinit` can stop. Each one ends where it stopped: the code after it does not run (it
-- would add 1000). None of them reaches the panic `A fiber that was cancelled stopped where it can not be
-- cancelled.`, which guards against a site without a cancel pad.
global ways int = 0
fn cancel_ways(fb Fiber, want int):
    ways = 0
    _ = fb.resume()
    test.eq(fb.cancel(), true)
    test.eq(ways, want)

-- In a function template, from the `@deinit` of a type template.
fn stop_any(x %T):
    ways += 1
    suspend
    ways += 100
type G[T Any]:
    v T
fn (&G[]) @deinit():
    ways += 1
    stop_any(self.v)
    ways += 1000
fn way_template():
    g := G[int]{v=1}
    h := G[float]{v=1.0}
    suspend
cancel_ways(fiber way_template(), 4)

-- Through a function pointer.
fn stop_plain():
    ways += 1
    suspend
    ways += 100
type ViaPtr:
    id int
fn (&ViaPtr) @deinit():
    p := stop_plain
    p()
    ways += 1000
fn way_ptr():
    v := ViaPtr{id=1}
    suspend
cancel_ways(fiber way_ptr(), 1)

-- In a lambda.
type ViaLambda:
    id int
fn (&ViaLambda) @deinit():
    f := fn():
        ways += 1
        suspend
        ways += 100
    f()
    ways += 1000
fn way_lambda():
    v := ViaLambda{id=1}
    suspend
cancel_ways(fiber way_lambda(), 1)

-- In a trait method.
type Stopper trait:
    fn stop() -> void
type StopImpl:
    with Stopper
    id int
fn (&StopImpl) stop() -> void:
    ways += 1
    suspend
    ways += 100
type ViaTrait:
    id int
fn (&ViaTrait) @deinit():
    var t ^Dyn[Stopper] = ^StopImpl{id=1}
    t.stop()
    ways += 1000
fn way_trait():
    v := ViaTrait{id=1}
    suspend
cancel_ways(fiber way_trait(), 1)

-- In the body of a generator that the `@deinit` consumes.
generator fn stop_gen() -> int:
    ways += 1
    suspend
    yield 1
type ViaGen:
    id int
fn (&ViaGen) @deinit():
    g := stop_gen()
    _ = g.next()
    ways += 1000
fn way_gen():
    v := ViaGen{id=1}
    suspend
cancel_ways(fiber way_gen(), 1)

-- At `Future.wait_any`, at `Fiber.wait_ready`, and in a `scope` block of its own.
type ViaAny:
    fut Future[int]
fn (&ViaAny) @deinit():
    ways += 1
    futs := []Future[int]{self.fut}
    _ = Future.wait_any(futs.span())
    ways += 1000
type ViaReady:
    id int
fn (&ViaReady) @deinit():
    ways += 1
    _ = Fiber.wait_ready()
    suspend
    ways += 1000
fn await_one(f Future[int]):
    _ = f.await()
fn join_one(f Future[int]) -> !void:
    scope |s|:
        s.start(await_one, {f})
type ViaScope:
    fut Future[int]
fn (&ViaScope) @deinit():
    ways += 1
    join_one(self.fut) !else:
        return
    ways += 1000
fn way_wait(f Future[int]):
    a := ViaAny{fut=f}
    b := ViaReady{id=1}
    c := ViaScope{fut=f}
    suspend
-- Nothing completes it.
way_never := FutureResolver.new(int)
cancel_ways(fiber way_wait(way_never.future()), 3)

--cytest: pass