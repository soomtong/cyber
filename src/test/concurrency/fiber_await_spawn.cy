use test
use os

-- An `await` inside a fiber suspends the fiber instead of waiting. The other fibers go on.
-- `slow` sleeps first: without it the thread of `a` could finish before `a` awaits, so `a` would not
-- suspend and its result would come before `b start`.
fn slow(n int) -> int:
    os.sleep(100000000).unwrap()
    sum := 0
    for 0..n |i|:
        sum += i
    return sum

fn worker(name str, n int, log ^ArrayStore[str]):
    f := spawn(slow, {n})
    log << '%{name} start'
    res := f.await()
    log << '%{name} got %{res}'

log := ^ArrayStore[str]{}
a := fiber worker('a', 200000, log)
b := fiber worker('b', 10, log)
while a.status() != .done or b.status() != .done:
    _ = a.resume()
    _ = b.resume()
    if a.waiting() and b.waiting():
        test.eq(Fiber.wait_ready(), true)
test.eq(log.len(), 4)
-- Both fibers started before either of them got its result: the awaits did not block.
test.eq(log[0], 'a start')
test.eq(log[1], 'b start')
-- The two results arrive in any order.
got_a := 'a got 19999900000'
got_b := 'b got 45'
test.eq((log[2] == got_a and log[3] == got_b) or (log[2] == got_b and log[3] == got_a), true)

--cytest: pass