use test

-- Futures dropped without `await`. Whichever of the owner and the spawned thread ends last frees the thread
-- and its result: the thread when it ends after the future was destructed, the owner otherwise.
for 0..200 |i|:
    _ = spawn label(i)
    _ = spawn sum(i % 40)
    keep := spawn label(i)
    if i % 2 == 0:
        test.eq(label(i), keep.await())

-- The owner keeps allocating while dropped futures' threads end.
words := Array[str]{}
for 0..2000 |i|:
    words.append('w' + i.fmt())
test.eq(2000, words.len())

-- Dropped futures inside a spawned thread.
test.eq(10, spawn drop_inner(10).await())

-- A result with a `@deinit` is destructed in the spawned thread's heap when its future is dropped.
for 0..20 |i|:
    _ = spawn make_box(i)

-- A future dropped after `Future.wait_any` saw its thread end.
pair := []Future[str]{spawn label(1), spawn label(2)}
idx := Future.wait_any(pair.span())
test.eq(true, idx == 0 or idx == 1)

type Box:
    n    int
    name str

fn (&Box) @send(dst Thread) -> Box:
    return Box{n = self.n, name = self.name.@send(dst)}

fn (&Box) @deinit():
    pass

fn make_box(n int) -> Box:
    return Box{n = n, name = 'box' + n.fmt()}

fn label(n int) -> str:
    return 'item-' + n.fmt() + '-' + n.fmt()

fn sum(n int) -> int:
    s := 0
    for 0..n |i|:
        s += i
    return s

fn drop_inner(n int) -> int:
    for 0..n |i|:
        _ = spawn label(i)
    return n

--cytest: pass