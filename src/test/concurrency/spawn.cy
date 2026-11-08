use test

-- No args.
test.eq(123, spawn(entry, {}).await())

-- Sending primitive.
test.eq(45, spawn(entry2, {10}).await())

-- Sending `str`.
test.eq('xyz', spawn(entry3, {'abc'}).await())

-- A spawned thread can `await` a future it spawned.
test.eq(41, spawn(nested, {20}).await())
test.eq('hi?!.', spawn(nested_str, {'hi'}).await())

-- A chain of awaiting threads deeper than the worker pool. Waiting threads run queued tasks themselves.
test.eq(30, chain(30))

-- Several threads awaiting their own children at once.
futs := Array[Future[int]]{}
for 0..8 |i|:
    futs.append(spawn(fan, {i}))
sum := 0
for futs |f|:
    sum += f.await()
test.eq(3132, sum)

fn entry() -> int:
    return 123

fn entry2(n int) -> int:
    sum := 0
    for 0..n |i|:
        sum += i
    return sum

fn entry3(s str) -> str:
    return 'xyz'

fn double(n int) -> int:
    return n * 2

fn nested(n int) -> int:
    return spawn(double, {n}).await() + 1

fn bang(s str) -> str:
    return s + '!'

fn nested_str(s str) -> str:
    return spawn(bang, {s + '?'}).await() + '.'

fn chain(n int) -> int:
    if n == 0:
        return 0
    return spawn(chain, {n - 1}).await() + 1

fn inc(n int) -> int:
    return n + 1

fn fan(n int) -> int:
    a := spawn(inc, {n})
    b := spawn(inc, {n * 10})
    c := spawn(inc, {n * 100})
    return a.await() + b.await() + c.await()

--cytest: pass