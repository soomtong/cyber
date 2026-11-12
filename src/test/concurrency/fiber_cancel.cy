use test

-- `Fiber.cancel` ends a suspended fiber. Each call that the fiber is in returns at once, innermost first, and
-- the values that the calls own are destructed as at a `return`.
type Res:
    id int
global dropped int = 0
fn (&Res) @deinit():
    dropped += 1

-- One frame, at a `suspend`.
fn one(log ^ArrayStore[str]):
    r := Res{id = 1}
    s := 'heap' + '-string-padding-padding-padding'
    log << 'before'
    suspend
    log << 'after %{s} %{r.id}'
log := ^ArrayStore[str]{}
f1 := fiber one(log)
test.eq(f1.resume(), .suspended)
test.eq(f1.cancel(), true)
test.eq(f1.status(), .done)
test.eq(f1.resume(), .done)
test.eq(log.len(), 1)
test.eq(dropped, 1)
-- A fiber that is done, and one that was never resumed.
test.eq(f1.cancel(), true)
f2 := fiber one(log)
test.eq(f2.cancel(), true)
test.eq(f2.status(), .done)
test.eq(log.len(), 1)

-- A chain of calls. Every frame destructs its own locals, and a value that a call returns is not made.
fn leaf(log ^ArrayStore[str]) -> Res:
    r := Res{id = 2}
    suspend
    log << 'leaf after'
    return Res{id = 20}
fn mid(log ^ArrayStore[str]) -> int:
    r := Res{id = 3}
    t := 'mid' + '-string-padding-padding-padding'
    got := leaf(log)
    log << 'mid after %{t}'
    return got.id
fn top(log ^ArrayStore[str]):
    r := Res{id = 4}
    x := mid(log) + 1
    log << 'top after %{x}'
dropped = 0
f3 := fiber top(log)
test.eq(f3.resume(), .suspended)
test.eq(f3.cancel(), true)
test.eq(log.len(), 1)
test.eq(dropped, 3)

-- Locals of nested blocks and loops, and a local that is assigned again.
fn blocks(log ^ArrayStore[str]):
    outer := Res{id = 5}
    for 0..3 |i|:
        inner := Res{id = 6}
        if i == 1:
            deepest := Res{id = 7}
            suspend
            log << 'not reached %{deepest.id}'
        log << 'round %{i} %{inner.id}'
    log << 'end %{outer.id}'
dropped = 0
log = ^ArrayStore[str]{}
f4 := fiber blocks(log)
test.eq(f4.resume(), .suspended)
-- The first round is over: its `inner` is gone.
test.eq(dropped, 1)
test.eq(f4.cancel(), true)
test.eq(dropped, 4)
test.eq(log.len(), 1)

-- A value in the middle of an expression: an argument that is done when a later argument suspends, and the
-- left side of an operator.
fn blocker(n int) -> int:
    suspend
    return n
fn use_both(r Res, n int) -> int:
    return r.id + n
fn make_text(n int) -> str:
    return 'text' + '-padding-padding-padding-%{n}'
fn middle(log ^ArrayStore[str]):
    a := use_both(Res{id = 8}, blocker(1))
    log << 'a %{a}'
    b := make_text(1) + make_text(blocker(2))
    log << b
dropped = 0
f5 := fiber middle(log)
test.eq(f5.resume(), .suspended)
test.eq(dropped, 0)
test.eq(f5.cancel(), true)
test.eq(dropped, 1)
f6 := fiber middle(log)
test.eq(f6.resume(), .suspended)
test.eq(f6.resume(), .suspended)
test.eq(f6.cancel(), true)
test.eq(log.len(), 2)

-- At an `await` and in `Future.wait_any`.
fn waits(fut Future[int], log ^ArrayStore[str]):
    r := Res{id = 9}
    v := fut.await()
    log << 'got %{v} %{r.id}'
fn waits_any(f1 Future[int], f2 Future[int], log ^ArrayStore[str]):
    r := Res{id = 10}
    futs := []Future[int]{f1, f2}
    k := Future.wait_any(futs.span())
    log << 'any %{k} %{r.id}'
dropped = 0
log = ^ArrayStore[str]{}
r1 := FutureResolver.new(int)
r2 := FutureResolver.new(int)
f7 := fiber waits(r1.future(), log)
f8 := fiber waits_any(r1.future(), r2.future(), log)
test.eq(f7.resume(), .suspended)
test.eq(f8.resume(), .suspended)
test.eq(f7.waiting(), true)
test.eq(f8.waiting(), true)
test.eq(f7.cancel(), true)
test.eq(f8.cancel(), true)
test.eq(f7.waiting(), false)
test.eq(dropped, 2)
test.eq(Fiber.wait_ready(), false)
r1.complete(1)
test.eq(log.len(), 0)

-- Methods, a function value, a closure and a trait method.
type Shape trait:
    fn area(log ^ArrayStore[str]) -> int
type Box:
    with Shape
    side int
fn (&Box) area(log ^ArrayStore[str]) -> int:
    r := Res{id = 11}
    suspend
    log << 'area'
    return self.side * self.side
fn (&Box) twice(log ^ArrayStore[str]) -> int:
    r := Res{id = 12}
    return self.area(log) * 2
type AreaFn = fn(^ArrayStore[str]) -> int
fn by_ptr(log ^ArrayStore[str]) -> int:
    r := Res{id = 13}
    suspend
    return 1
fn calls(kind int, log ^ArrayStore[str]):
    r := Res{id = 14}
    box := ^Box{side = 2}
    if kind == 0:
        log << 'twice %{box.twice(log)}'
    else kind == 1:
        ptr := by_ptr
        log << 'ptr %{ptr(log)}'
    else kind == 2:
        held := ^Res{id = 15}
        func := fn(log2 ^ArrayStore[str]) -> int:
            suspend
            return held.id
        log << 'closure %{func(log)}'
    else:
        var shape ^Dyn[Shape] = ^Box{side = 3}
        log << 'trait %{shape.area(log)}'
for 0..4 |kind|:
    dropped = 0
    log = ^ArrayStore[str]{}
    fk := fiber calls(kind, log)
    test.eq(fk.resume(), .suspended)
    test.eq(fk.cancel(), true)
    test.eq(log.len(), 0)
    if kind == 0:
        test.eq(dropped, 3)
    else kind == 2:
        test.eq(dropped, 2)
    else:
        test.eq(dropped, 2)

-- A `fiber:` block.
dropped = 0
count := ^0
f9 := fiber:
    r := Res{id = 16}
    count.* += 1
    suspend
    count.* += 1
test.eq(f9.resume(), .suspended)
test.eq(f9.cancel(), true)
test.eq(count.*, 1)
test.eq(dropped, 1)

-- A fiber that is destructed while it is in progress is cancelled, and so is a fiber that it holds.
fn inner_work(log ^ArrayStore[str]):
    r := Res{id = 17}
    suspend
    log << 'inner after'
fn outer_work(log ^ArrayStore[str]):
    r := Res{id = 18}
    child := fiber inner_work(log)
    _ = child.resume()
    suspend
    log << 'outer after'
fn start_and_leave(log ^ArrayStore[str]):
    f := fiber outer_work(log)
    test.eq(f.resume(), .suspended)
dropped = 0
log = ^ArrayStore[str]{}
start_and_leave(log)
test.eq(dropped, 2)
test.eq(log.len(), 0)

-- A fiber that is suspended in the body of a generator is cancelled: the body's locals are destructed and
-- the generator is done.
fn pause(r &Res):
    suspend
generator fn numbers() -> int:
    r := Res{id = 1}
    yield 1
    suspend
    yield 2
    pause(&r)
    yield 3
fn consume(out ^int):
    r := Res{id = 2}
    for numbers() |n|:
        out.* += n
total := ^0
dropped = 0
f10 := fiber consume(total)
test.eq(f10.resume(), .suspended)
test.eq(f10.cancel(), true)
test.eq(f10.status(), .done)
test.eq(total.*, 1)
test.eq(dropped, 2)

-- Suspended in a call of the generator body.
dropped = 0
total.* = 0
f11 := fiber consume(total)
test.eq(f11.resume(), .suspended)
test.eq(f11.resume(), .suspended)
test.eq(f11.cancel(), true)
test.eq(total.*, 3)
test.eq(dropped, 2)

-- A generator that consumes a generator.
generator fn tens() -> int:
    r := Res{id = 3}
    for numbers() |n|:
        yield n * 10
fn consume_tens(out ^int):
    for tens() |n|:
        out.* += n
dropped = 0
total.* = 0
f12 := fiber consume_tens(total)
test.eq(f12.resume(), .suspended)
test.eq(f12.cancel(), true)
test.eq(total.*, 10)
test.eq(dropped, 2)

-- Dropped in progress.
fn start_consume(out ^int):
    f := fiber consume(out)
    test.eq(f.resume(), .suspended)
dropped = 0
start_consume(total)
test.eq(dropped, 2)

-- The generator runs to its end outside a fiber.
total.* = 0
consume(total)
test.eq(total.*, 6)

-- A fiber that is suspended in a destructor at the end of a block: the value is not destructed again.
global slow_drops int = 0
type Slow:
    with NoCopy
    id int
fn (&Slow) @deinit():
    slow_drops += 1
    if slow_drops == 1:
        suspend
fn hold_slow():
    a := Slow{id = 1}
    b := Slow{id = 2}
fn start_slow():
    f := fiber hold_slow()
    test.eq(f.resume(), .suspended)
start_slow()
test.eq(slow_drops, 2)

--cytest: pass