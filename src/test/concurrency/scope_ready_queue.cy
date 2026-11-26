use test

-- `Scope.run` resumes the fibers that can go on: one that awaits a future is put in the scope's queue when the
-- future is completed, instead of being asked in every round (`fiber_wait.zig`).

-- Checks the log against the expected values.
fn same(log ^Array[int], exp []int):
    test.eq(log.*.len(), exp.len())
    for 0..exp.len() |i|:
        test.eq(log.*[i], exp[i])

fn waiter(n int, f Future[int], log ^Array[int]):
    v := f.await()
    log.* << (n * 10 + v)

fn completer(rs ^Array[FutureResolver[int]], order []int):
    for 0..order.len() |i|:
        rs.*[order[i]].complete(i)
        suspend

-- The waiters go on in the order their futures are completed.
fn completion_order() -> !void:
    rs := ^Array[FutureResolver[int]]{}
    for 0..3:
        rs.* << FutureResolver.new(int)
    log := ^Array[int]{}
    scope |s|:
        for 0..3 |i|:
            s.start(waiter, {i, rs.*[i].future(), log})
        s.start(completer, {rs, []int{2, 0, 1}})
    test.eq(log.*.len(), 3)
    test.eq(log.*[0], 20)
    test.eq(log.*[1], 1)
    test.eq(log.*[2], 12)
completion_order()!

-- Fibers that only suspend take turns in the order they were started.
fn stepper(id int, k int, log ^Array[int]):
    for 0..k:
        log.* << id
        suspend

fn round_robin() -> !void:
    log := ^Array[int]{}
    scope |s|:
        s.start(stepper, {1, 2, log})
        s.start(stepper, {2, 3, log})
        s.start(stepper, {3, 1, log})
    same(log, []int{1, 2, 3, 1, 2, 2})
round_robin()!

-- A fiber of `Future.wait_any` is woken once when both futures complete before it runs again. It returns the first
-- one in its list that is done.
fn any_waiter(a Future[int], b Future[int], log ^Array[int]):
    futs := []Future[int]{a, b}
    idx := Future.wait_any(futs.span())
    log.* << idx

fn wait_any_once() -> !void:
    rs := ^Array[FutureResolver[int]]{}
    rs.* << FutureResolver.new(int)
    rs.* << FutureResolver.new(int)
    log := ^Array[int]{}
    scope |s|:
        s.start(any_waiter, {rs.*[0].future(), rs.*[1].future(), log})
        s.start(both, {rs})
    same(log, []int{0})

fn both(rs ^Array[FutureResolver[int]]):
    suspend
    rs.*[1].complete(1)
    rs.*[0].complete(0)
wait_any_once()!

-- A fiber of the scope that runs fibers of its own and waits in `Fiber.wait_ready` is woken by a future of a fiber
-- that it runs.
fn own_loop(f Future[int], log ^Array[int]):
    w := fiber waiter(7, f, log)
    while w.status() != .done:
        if w.waiting():
            _ = Fiber.wait_ready()
        else:
            _ = w.resume()
    log.* << 100

fn later(r ^FutureResolver[int]):
    for 0..3:
        suspend
    r.*.complete(5)

fn manual_wait_ready() -> !void:
    r := ^FutureResolver.new(int)
    log := ^Array[int]{}
    scope |s|:
        s.start(own_loop, {r.*.future(), log})
        s.start(later, {r})
    same(log, []int{75, 100})
manual_wait_ready()!

-- The future is completed before the fiber that awaits it is resumed again: it goes on in the next turn.
fn early(r ^FutureResolver[int], log ^Array[int]):
    r.*.complete(3)
    log.* << 1

fn completed_before() -> !void:
    r := ^FutureResolver.new(int)
    log := ^Array[int]{}
    scope |s|:
        s.start(waiter, {2, r.*.future(), log})
        s.start(early, {r, log})
    same(log, []int{1, 23})
completed_before()!

-- An error cancels the fibers that wait for a future, which never completes.
type Guard:
    log ^Array[int]

fn (&Guard) @deinit():
    self.log.* << -1

fn guarded(f Future[int], log ^Array[int]):
    g := Guard{log=log}
    _ = f.await()
    log.* << 99

fn failing() -> !void:
    suspend
    return error.Failed

fn cancel_waiting() -> !void:
    r := FutureResolver.new(int)
    log := ^Array[int]{}
    try:
        scope |s|:
            s.start(guarded, {r.future(), log})
            s.start(guarded, {r.future(), log})
            s.start(failing, {})
    else |err|:
        test.eq(err, error.Failed)
    same(log, []int{-1, -1})
cancel_waiting()!

-- A fiber that waits in its `scope` block is cancelled: the scope cancels its fibers that wait for a future.
fn holder(f Future[int], log ^Array[int]):
    try:
        scope |s|:
            s.start(guarded, {f, log})
            s.start(guarded, {f, log})
    else:
        log.* << -2

fn cancel_holder():
    r := FutureResolver.new(int)
    log := ^Array[int]{}
    h := fiber holder(r.future(), log)
    test.eq(h.resume(), .suspended)
    test.eq(h.waiting(), true)
    test.eq(h.cancel(), true)
    same(log, []int{-1, -1})
cancel_holder()

-- `abort` cancels the fibers that wait. Without a `join` they never ran.
fn abort_waiting() -> !void:
    r := FutureResolver.new(int)
    log := ^Array[int]{}
    s := Scope.new()
    s.start(guarded, {r.future(), log})
    s.start(stepper, {5, 1, log})
    test.eq(s.active(), 2)
    s.abort()
    test.eq(s.active(), 0)
    same(log, []int{})
abort_waiting()!

-- Waiters in nested scopes, completed in a mixed order, with a fiber that only suspends next to them.
fn group(rs ^Array[FutureResolver[int]], base int, log ^Array[int]) -> !void:
    scope |s|:
        for 0..3 |i|:
            s.start(waiter, {base + i, rs.*[base + i].future(), log})

fn nested() -> !void:
    rs := ^Array[FutureResolver[int]]{}
    for 0..9:
        rs.* << FutureResolver.new(int)
    log := ^Array[int]{}
    steps := ^Array[int]{}
    scope |s|:
        for 0..3 |g|:
            s.start(group, {rs, g * 3, log})
        s.start(stepper, {0, 20, steps})
        s.start(completer, {rs, []int{8, 0, 4, 2, 6, 1, 7, 3, 5}})
    test.eq(log.*.len(), 9)
    sum := 0
    for 0..log.*.len() |i|:
        sum += log.*[i]
    -- ids 0..8 times 10 and the values 0..8.
    test.eq(sum, 36 * 10 + 36)
    test.eq(log.*[0], 80)
    test.eq(steps.*.len(), 20)
nested()!

--cytest: pass
