use test

-- Nested scopes whose fibers await futures. `Fiber.waiting` of a fiber that waits in a nested scope keeps its answer
-- between futures that are completed, so these check that the answer follows each completion.

fn waiter(f Future[int], sum ^int):
    v := f.await()
    sum.* += v

fn group(fs ^Array[Future[int]], base int, k int, sum ^int) -> !void:
    scope |s|:
        for 0..k |i|:
            s.start(waiter, {fs.*[base + i], sum})

-- Completes one future per round, last group first.
fn driver(rs ^Array[FutureResolver[int]], order ^Array[int]) -> !void:
    for 0..rs.*.len() |i|:
        idx := rs.*.len() - 1 - i
        rs.*[idx].complete(idx + 1)
        order.* << idx
        suspend

fn run(m int, k int, fs ^Array[Future[int]], rs ^Array[FutureResolver[int]], sum ^int, order ^Array[int]) -> !void:
    scope |s|:
        for 0..m |g|:
            s.start(group, {fs, g * k, k, sum})
        s.start(driver, {rs, order})

fn check_driver(m int, k int) -> !void:
    rs := ^Array[FutureResolver[int]]{}
    fs := ^Array[Future[int]]{}
    for 0..m*k |i|:
        rs.* << FutureResolver.new(int)
        fs.* << rs.*[i].future()
    sum := ^0
    order := ^Array[int]{}
    run(m, k, fs, rs, sum, order)!
    test.eq(sum.*, (m * k) * (m * k + 1) / 2)
    test.eq(order.*.len(), m * k)
check_driver(1, 1)!
check_driver(3, 2)!
check_driver(20, 4)!

-- The root context completes the futures between the joins of a scope that it holds. Each join runs the group
-- whose future is done, and stops again when only groups that wait are left.
fn check_root() -> !void:
    rs := ^Array[FutureResolver[int]]{}
    fs := ^Array[Future[int]]{}
    for 0..6 |i|:
        rs.* << FutureResolver.new(int)
        fs.* << rs.*[i].future()
    sum := ^0
    var s Scope = Scope.new()
    for 0..3 |g|:
        s.start(group, {fs, g * 2, 2, sum})
    -- A fiber that only gives control back, so the join does not wait for the futures.
    steps := ^0
    s.start(stepper, {steps, rs})
    s.join()!
    test.eq(sum.*, 21)
    test.eq(steps.*, 6)
    test.eq(s.active(), 0)

-- Completes a future of a different group each time it runs.
fn stepper(steps ^int, rs ^Array[FutureResolver[int]]):
    for 0..6 |i|:
        idx := (i * 2 + i / 3) % 6
        rs.*[idx].complete(idx + 1)
        steps.* += 1
        suspend
check_root()!

--cytest: pass
