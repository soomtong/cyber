use test

-- The fibers of a scope take turns at `suspend` and are all done after `join`.
fn step(name str, n int, log ^ArrayStore[str]):
    for 0..n |i|:
        log << '%{name}%{i}'
        suspend

fn run_steps() -> !void:
    log := ^ArrayStore[str]{}
    s := Scope.new()
    s.start(step, {'a', 2, log})
    s.start(step, {'b', 3, log})
    test.eq(s.active(), 2)
    test.eq(log.len(), 0)
    s.join()!
    test.eq(s.active(), 0)
    test.eq(log.len(), 5)
    test.eq(log[0], 'a0')
    test.eq(log[1], 'b0')
    test.eq(log[2], 'a1')
    test.eq(log[3], 'b1')
    test.eq(log[4], 'b2')

    -- A scope can be used again after a `join`.
    s.start(step, {'c', 1, log})
    s.join()!
    test.eq(log[5], 'c0')
run_steps()!

-- `join` returns the first error. A fiber in progress runs to its end, one that was not started is dropped.
type Res:
    id int
global dropped int = 0
fn (&Res) @deinit():
    dropped += 1

fn fail_later(log ^ArrayStore[str]) -> !void:
    log << 'fail start'
    suspend
    return error.Failed

fn slow(log ^ArrayStore[str]) -> !void:
    log << 'slow start'
    suspend
    suspend
    log << 'slow end'

fn never(r Res, log ^ArrayStore[str]):
    log << 'never'

fn run_failing(log ^ArrayStore[str]) -> !void:
    s := Scope.new()
    s.start(fail_later, {log})
    s.start(slow, {log})
    s.join()!
    log << 'not reached'

fn check_failing():
    log := ^ArrayStore[str]{}
    res := run_failing(log)
    test.eq(res.unwrap_error(), error.Failed)
    test.eq(log.len(), 3)
    test.eq(log[0], 'fail start')
    test.eq(log[1], 'slow start')
    test.eq(log[2], 'slow end')
check_failing()

fn second_fails() -> !void:
    return error.Second

fn run_dropping(log ^ArrayStore[str]) -> !void:
    s := Scope.new()
    s.start(fail_later, {log})
    s.join() !else |err|:
        -- Started after the failure: never entered, the arguments are released.
        s.start(never, {Res{id = 1}, log})
        s.start(second_fails, {})
        s.join()!
        return err

fn check_dropping():
    log := ^ArrayStore[str]{}
    dropped = 0
    res := run_dropping(log)
    test.eq(res.unwrap_error(), error.Failed)
    test.eq(log.len(), 1)
    test.eq(dropped, 1)
check_dropping()

-- A block that is left early joins its fibers first.
fn early(log ^ArrayStore[str], leave bool) -> int:
    s := Scope.new()
    s.start(step, {'e', 2, log})
    if leave:
        return 1
    return 2

fn check_early():
    log := ^ArrayStore[str]{}
    test.eq(early(log, true), 1)
    test.eq(log.len(), 2)
    test.eq(early(log, false), 2)
    test.eq(log.len(), 4)
check_early()

-- A scope inside a fiber of another scope.
fn inner_group(name str, log ^ArrayStore[str]) -> !void:
    s := Scope.new()
    s.start(step, {name + 'x', 2, log})
    s.start(step, {name + 'y', 1, log})
    s.join()!
    log << '%{name} done'

fn check_nested() -> !void:
    log := ^ArrayStore[str]{}
    s := Scope.new()
    s.start(inner_group, {'p', log})
    s.start(inner_group, {'q', log})
    s.join()!
    test.eq(log.len(), 8)
    test.eq(log[log.len() - 1], 'q done')
check_nested()!

-- Fibers that wait for futures. The scope waits when all of them wait.
fn waiter(fut Future[int], out ^int):
    -- The value first: `out.* += fut.await()` reads `out.*` before the fiber is suspended.
    v := fut.await()
    out.* += v

fn completer(r ^FutureResolver[int], n int):
    suspend
    r.complete(n)

fn check_futures() -> !void:
    out := ^0
    r1 := ^FutureResolver.new(int)
    r2 := ^FutureResolver.new(int)
    s := Scope.new()
    s.start(waiter, {r1.future(), out})
    s.start(waiter, {r2.future(), out})
    s.start(completer, {r2, 20})
    s.start(completer, {r1, 1})
    s.join()!
    test.eq(out.*, 21)
check_futures()!

--cytest: pass
