use test

-- No fiber awaits a future.
test.eq(Fiber.wait_ready(), false)

-- A future that the root context completes. A fiber that waits is not entered by `resume`.
fn waiter(fut Future[int], out ^int, steps ^int):
    steps.* += 1
    out.* = fut.await()
    steps.* += 1
r := FutureResolver.new(int)
out := ^0
steps := ^0
w := fiber waiter(r.future(), out, steps)
test.eq(w.waiting(), false)
test.eq(w.resume(), .suspended)
test.eq(w.waiting(), true)
test.eq(w.status(), .suspended)
test.eq(w.resume(), .suspended)
test.eq(steps.*, 1)
r.complete(7)
test.eq(w.waiting(), false)
test.eq(Fiber.wait_ready(), true)
test.eq(w.resume(), .done)
test.eq(out.*, 7)
test.eq(steps.*, 2)

-- A completed future does not suspend the fiber.
fn ready(out ^int):
    out.* = Future.complete(3).await()
out2 := ^0
f3 := fiber ready(out2)
test.eq(f3.resume(), .done)
test.eq(out2.*, 3)

-- `Future.wait_any` inside a fiber suspends the fiber too.
fn any_of(r1 Future[int], r2 Future[int], out ^int):
    futs := []Future[int]{r1, r2}
    k := Future.wait_any(futs.span())
    out.* = k * 100 + futs[k].await()
ra := FutureResolver.new(int)
rb := FutureResolver.new(int)
out3 := ^0
f4 := fiber any_of(ra.future(), rb.future(), out3)
test.eq(f4.resume(), .suspended)
test.eq(f4.waiting(), true)
rb.complete(5)
test.eq(f4.waiting(), false)
test.eq(f4.resume(), .done)
test.eq(out3.*, 105)

-- The await of a nested fiber goes back to the fiber that resumed it.
fn inner(fut Future[int], out ^int):
    out.* = fut.await()
fn outer(fut Future[int], out ^int, seen ^ArrayStore[bool]):
    child := fiber inner(fut, out)
    while child.resume() != .done:
        seen << child.waiting()
        suspend
rc := FutureResolver.new(int)
out4 := ^0
seen := ^ArrayStore[bool]{}
f5 := fiber outer(rc.future(), out4, seen)
test.eq(f5.resume(), .suspended)
test.eq(f5.waiting(), false)
test.eq(f5.resume(), .suspended)
rc.complete(9)
test.eq(f5.resume(), .done)
test.eq(out4.*, 9)
test.eq(seen.len(), 2)
test.eq(seen[0], true)

-- An await in a generator body suspends the fiber that consumes the generator.
generator fn answers(fut Future[int]) -> int:
    yield fut.await()
    yield 1
fn consume(fut Future[int], out ^int):
    for answers(fut) |v|:
        out.* += v
rd := FutureResolver.new(int)
out5 := ^0
f6 := fiber consume(rd.future(), out5)
test.eq(f6.resume(), .suspended)
test.eq(f6.waiting(), true)
rd.complete(40)
test.eq(f6.resume(), .done)
test.eq(out5.*, 41)

--cytest: pass
