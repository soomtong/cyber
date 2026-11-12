use test

type Res:
    id int
global dropped int = 0
fn (&Res) @deinit():
    dropped += 1

fn step(name str, n int, log ^ArrayStore[str]):
    held := Res{id = n}
    for 0..n |i|:
        log << '%{name}%{i}'
        suspend

fn fails(log ^ArrayStore[str]) -> !void:
    log << 'fails'
    suspend
    return error.Child

fn check(ok bool) -> !int:
    if !ok:
        return error.Body
    return 1

-- The fibers are done when the block is.
fn all(log ^ArrayStore[str]) -> !void:
    scope |s|:
        s.start(step, {'a', 2, log})
        s.start(step, {'b', 1, log})
        test.eq(s.active(), 2)
        test.eq(log.len(), 0)
    log << 'after'

fn check_all() -> !void:
    log := ^ArrayStore[str]{}
    dropped = 0
    all(log)!
    test.eq(log.len(), 4)
    test.eq(log[0], 'a0')
    test.eq(log[1], 'b0')
    test.eq(log[2], 'a1')
    test.eq(log[3], 'after')
    test.eq(dropped, 2)
check_all()!

-- An error of a fiber comes out of the block like at a `!`. The other fibers are cancelled.
fn child_fails(log ^ArrayStore[str]) -> !void:
    scope |s|:
        s.start(step, {'a', 5, log})
        s.start(fails, {log})
    log << 'not reached'

fn check_child_fails():
    log := ^ArrayStore[str]{}
    dropped = 0
    res := child_fails(log)
    test.eq(res.unwrap_error(), error.Child)
    test.eq(log.len(), 3)
    test.eq(log[0], 'a0')
    test.eq(log[1], 'fails')
    test.eq(log[2], 'a1')
    test.eq(dropped, 1)
check_child_fails()

-- A failing `!` in the body cancels the fibers that were started. None of them runs.
fn body_fails(log ^ArrayStore[str], ok bool) -> !int:
    total := 0
    scope |s|:
        s.start(step, {'a', 3, log})
        total += check(ok)!
        s.start(step, {'b', 1, log})
    return total

fn check_body_fails() -> !void:
    log := ^ArrayStore[str]{}
    dropped = 0
    res := body_fails(log, false)
    test.eq(res.unwrap_error(), error.Body)
    test.eq(log.len(), 0)
    -- The fiber was not started: its function never made a `Res`.
    test.eq(dropped, 0)
    test.eq(body_fails(log, true)!, 1)
    test.eq(log.len(), 4)
check_body_fails()!

-- `return` and `break` leave the block after the fibers are done.
fn returns(log ^ArrayStore[str]) -> !int:
    scope |s|:
        s.start(step, {'r', 2, log})
        return 7
fn breaks(log ^ArrayStore[str]) -> !int:
    rounds := 0
    while true:
        rounds += 1
        scope |s|:
            s.start(step, {'k', 1, log})
            if rounds == 2:
                break
    return rounds

fn check_exits() -> !void:
    log := ^ArrayStore[str]{}
    test.eq(returns(log)!, 7)
    test.eq(log.len(), 2)
    test.eq(breaks(log)!, 2)
    test.eq(log.len(), 4)
check_exits()!

-- Inside a `try` block the error goes to the `else` block. Blocks can be nested.
fn in_try(log ^ArrayStore[str]) -> str:
    try:
        scope |outer|:
            outer.start(step, {'o', 1, log})
            scope |inner|:
                inner.start(fails, {log})
            log << 'not reached'
    else |err|:
        return 'caught %{err}'
    return 'none'

fn check_try():
    log := ^ArrayStore[str]{}
    test.eq(in_try(log), 'caught error.Child')
    test.eq(log.len(), 1)
    test.eq(log[0], 'fails')
check_try()

-- A fiber that is inside a `scope` block of its own is cancelled with its fibers: they wait for futures that
-- are never completed.
fn waits(fut Future[int], name str, log ^ArrayStore[str]):
    held := Res{id = 1}
    log << ('wait ' + name)
    _ = fut.await()
    log << ('got ' + name)
fn group(f1 Future[int], f2 Future[int], log ^ArrayStore[str]) -> !void:
    scope |s|:
        s.start(waits, {f1, 'a', log})
        s.start(waits, {f2, 'b', log})
    log << 'group done'
fn fails_late(log ^ArrayStore[str]) -> !void:
    suspend
    suspend
    return error.Late
fn group_and_fail(f1 Future[int], f2 Future[int], log ^ArrayStore[str]) -> !void:
    scope |s|:
        s.start(group, {f1, f2, log})
        s.start(fails_late, {log})
fn check_group_cancel():
    log := ^ArrayStore[str]{}
    r1 := FutureResolver.new(int)
    r2 := FutureResolver.new(int)
    dropped = 0
    res := group_and_fail(r1.future(), r2.future(), log)
    test.eq(res.unwrap_error(), error.Late)
    test.eq(log.len(), 2)
    test.eq(log[0], 'wait a')
    test.eq(log[1], 'wait b')
    test.eq(dropped, 2)
check_group_cancel()

-- The same with `Scope.join` called directly, under a plain fiber.
fn joins(fut Future[int], log ^ArrayStore[str]):
    s := Scope.new()
    s.start(waits, {fut, 'c', log})
    _ = s.join()
fn check_join_cancel():
    log := ^ArrayStore[str]{}
    r := FutureResolver.new(int)
    dropped = 0
    f := fiber joins(r.future(), log)
    test.eq(f.resume(), .suspended)
    test.eq(f.cancel(), true)
    test.eq(log.len(), 1)
    test.eq(dropped, 1)
check_join_cancel()

-- The fibers that come after the failed one in the same round do not get a turn. One that did not start
-- never calls its function.
fn fail_now() -> !void:
    return error.Now
fn never(r ^Res, out ^int):
    out.* += 100
fn first_fails(out ^int) -> !void:
    scope |s|:
        s.start(fail_now, {})
        s.start(never, {^Res{id = 2}, out})
        s.start(never, {^Res{id = 3}, out})
fn check_first_fails():
    out := ^0
    dropped = 0
    test.eq(first_fails(out).unwrap_error(), error.Now)
    test.eq(out.*, 0)
    test.eq(dropped, 2)
check_first_fails()

-- A group that waits gives control back when a future outside of it is done: the fiber that awaits that
-- future belongs to the outer block.
fn adds(fut Future[int], out ^int):
    v := fut.await()
    out.* += v
fn add_group(f1 Future[int], f2 Future[int], out ^int) -> !void:
    scope |s|:
        s.start(adds, {f1, out})
        s.start(adds, {f2, out})
fn completer(r3 FutureResolver[int], r1 FutureResolver[int], r2 FutureResolver[int]):
    suspend
    r3.complete(3)
    suspend
    suspend
    r1.complete(1)
    r2.complete(2)
fn check_group_yields() -> !void:
    out := ^0
    r1 := FutureResolver.new(int)
    r2 := FutureResolver.new(int)
    r3 := FutureResolver.new(int)
    scope |s|:
        s.start(add_group, {r1.future(), r2.future(), out})
        s.start(adds, {r3.future(), out})
        s.start(completer, {r3, r1, r2})
    test.eq(out.*, 6)
check_group_yields()!

-- At the top level an error panics, like `!`. Without an error the block is an ordinary statement.
top_log := ^ArrayStore[str]{}
scope |s|:
    s.start(step, {'t', 1, top_log})
test.eq(top_log.len(), 1)

--cytest: pass
