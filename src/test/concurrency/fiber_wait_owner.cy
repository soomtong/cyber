use test

-- A fiber in `Fiber.wait_ready` waits for the fibers that it runs: the ones that it resumed last or asked `waiting()`
-- about last, and the ones that those run. A future of a fiber that another fiber runs does not end its wait.
-- Before, any future of the thread did: every group that waited was resumed for one round.

fn waiter(f Future[int], sum ^int):
    v := f.await()
    sum.* += v

-- A scheduler loop for one fiber. `rounds` counts its turns.
fn group(f Future[int], rounds ^int, sum ^int):
    w := fiber waiter(f, sum)
    while w.status() != .done:
        rounds.* += 1
        if w.waiting():
            _ = Fiber.wait_ready()
        else:
            _ = w.resume()

fn two_groups():
    r1 := FutureResolver.new(int)
    r2 := FutureResolver.new(int)
    n1 := ^0
    n2 := ^0
    sum := ^0
    g1 := fiber group(r1.future(), n1, sum)
    g2 := fiber group(r2.future(), n2, sum)
    test.eq(g1.resume(), .suspended)
    test.eq(g2.resume(), .suspended)
    test.eq(g1.waiting(), true)
    test.eq(g2.waiting(), true)

    -- Only the group that runs the fiber of this future goes on.
    r2.complete(5)
    test.eq(g1.waiting(), true)
    test.eq(g2.waiting(), false)
    test.eq(g2.resume(), .done)
    test.eq(n2.*, 3)
    test.eq(n1.*, 2)

    r1.complete(1)
    test.eq(g1.waiting(), false)
    test.eq(g1.resume(), .done)
    test.eq(n1.*, 3)
    test.eq(sum.*, 6)
two_groups()

-- A group of groups: the outer one goes on for a future two levels down, and only then.
fn outer(f Future[int], rounds ^int, inner_rounds ^int, sum ^int):
    g := fiber group(f, inner_rounds, sum)
    while g.status() != .done:
        rounds.* += 1
        if g.waiting():
            _ = Fiber.wait_ready()
        else:
            _ = g.resume()

fn nested():
    r1 := FutureResolver.new(int)
    r2 := FutureResolver.new(int)
    n1 := ^0
    m1 := ^0
    n2 := ^0
    m2 := ^0
    sum := ^0
    o1 := fiber outer(r1.future(), n1, m1, sum)
    o2 := fiber outer(r2.future(), n2, m2, sum)
    test.eq(o1.resume(), .suspended)
    test.eq(o2.resume(), .suspended)
    r1.complete(7)
    test.eq(o2.waiting(), true)
    test.eq(o1.waiting(), false)
    test.eq(o1.resume(), .done)
    test.eq(sum.*, 7)
    r2.complete(8)
    test.eq(o2.waiting(), false)
    test.eq(o2.resume(), .done)
    test.eq(sum.*, 15)
nested()

-- A fiber that the root context resumed is handed to another fiber. That one runs it from the moment it asks
-- `waiting()`, so its `wait_ready` waits for the future.
type Box:
    f ?Fiber

fn taker(b ^Box):
    while b.f.?.status() != .done:
        if b.f.?.waiting():
            _ = Fiber.wait_ready()
        else:
            _ = b.f.?.resume()

fn handed_over():
    r := FutureResolver.new(int)
    sum := ^0
    b := ^Box{f = fiber waiter(r.future(), sum)}
    test.eq(b.f.?.resume(), .suspended)
    t := fiber taker(b)
    test.eq(t.resume(), .suspended)
    test.eq(t.waiting(), true)
    r.complete(10)
    test.eq(t.waiting(), false)
    test.eq(t.resume(), .done)
    test.eq(sum.*, 10)
handed_over()

-- A fiber that runs no fiber that awaits has nothing to wait for.
fn alone(out ^int):
    if !Fiber.wait_ready():
        out.* = 1

fn nothing_owned():
    r := FutureResolver.new(int)
    sum := ^0
    w := fiber waiter(r.future(), sum)
    test.eq(w.resume(), .suspended)
    out := ^0
    a := fiber alone(out)
    test.eq(a.resume(), .done)
    test.eq(out.*, 1)
    r.complete(2)
    test.eq(w.resume(), .done)
nothing_owned()

--cytest: pass
