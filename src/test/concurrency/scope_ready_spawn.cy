use test

-- A fiber of a scope that awaits a spawned thread goes on while another fiber keeps the ready queue busy. The owner
-- checks the futures of spawned threads when the worker pool made progress (`fiber_wait.pollShared`).

fn square(n int) -> int:
    return n * n

fn ask(n int, out ^int, done ^bool):
    out.* = spawn square(n).await()
    done.* = true

-- Suspends until the other fiber is done. It would never end if the waiting fiber were not woken.
fn busy(done ^bool, turns ^int):
    while !done.*:
        turns.* += 1
        suspend

fn flat() -> !void:
    out := ^0
    done := ^false
    turns := ^0
    scope |s|:
        s.start(ask, {7, out, done})
        s.start(busy, {done, turns})
    test.eq(out.*, 49)
flat()!

fn inner(n int, out ^int, done ^bool) -> !void:
    scope |s|:
        s.start(ask, {n, out, done})

-- The waiting fiber is in a nested scope, whose own fiber waits in `@scope_wait`.
fn nested() -> !void:
    out := ^0
    done := ^false
    turns := ^0
    scope |s|:
        s.start(inner, {9, out, done})
        s.start(busy, {done, turns})
    test.eq(out.*, 81)
nested()!

-- Every fiber waits: the root context sleeps until a thread is done.
fn all_wait() -> !void:
    outs := ^Array[int]{}
    for 0..3:
        outs.* << 0
    scope |s|:
        for 0..3 |i|:
            s.start(ask_at, {i, outs})
    test.eq(outs.*[0] + outs.*[1] + outs.*[2], 0 + 1 + 4)

fn ask_at(i int, outs ^Array[int]):
    outs.*[i] = spawn square(i).await()
all_wait()!

--cytest: pass
