use test

-- A spawned thread's result stays in its own heap until the owner of the future takes it. The owner copies it
-- with `@send` on its own thread, so the spawned thread never allocates in the owner's heap while the owner runs.
futs := Array[Future[str]]{}
for 0..64 |i|:
    futs.append(spawn label(i))
words := Array[str]{}
for 0..2000 |i|:
    words.append('w' + i.fmt())
total := 0
for futs |f|:
    total += f.await().len()
test.eq(620, total)
test.eq(2000, words.len())

-- Awaiting twice returns the received result again.
twice := spawn label(7)
test.eq('item-7-7', twice.await())
test.eq('item-7-7', twice.await())

-- A spawned thread that awaits its own children while it allocates.
test.eq(280, spawn gather(10).await())

-- A result with a `@deinit` is destructed in the spawned thread's heap once it was copied out.
test.eq(3, spawn make_box(3).await().n)
test.eq('box4', spawn make_box(4).await().name)

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

fn gather(n int) -> int:
    kids := Array[Future[str]]{}
    for 0..n |i|:
        kids.append(spawn label(i))
    parts := Array[str]{}
    for 0..200 |i|:
        parts.append('p' + i.fmt())
    total := 0
    for kids |k|:
        total += k.await().len()
    return total + parts.len()

--cytest: pass