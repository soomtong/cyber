use t 'test'

-- A `return` without a value returns from a function that returns `void`.
count := ^0
fn note(count ^int, x int) -> void:
    if x > 3:
        return
    count.* += 1
note(count, 5)
note(count, 1)
t.eq(count.*, 1)

-- The return type is left out.
fn note2(count ^int, x int):
    if x > 3:
        return
    count.* += 1
note2(count, 5)
note2(count, 1)
t.eq(count.*, 2)

-- `!void`: the `return` is the success.
fn check(x int) -> !void:
    if x > 3:
        return
    return error.Small
check(5)!
t.eq(check(1).unwrap_error(), error.Small)

-- A lambda and a method.
f := fn(x int) -> void:
    if x > 3:
        return
    count.* += 1
f(5)
f(1)
t.eq(count.*, 3)

type Counter:
    n ^int

fn (&Counter) add(x int):
    if x > 3:
        return
    self.n.* += x
c := Counter{n=^0}
c.add(5)
c.add(2)
t.eq(c.n.*, 2)

-- A generator: the `return` ends it. `next` returns `none` and the generator is done.
generator fn upto(n int) -> int:
    yield 1
    if n < 2:
        return
    yield 2
g := upto(1)
t.eq(g.next().?, 1)
t.eq(g.next() == none, true)
t.eq(g.status(), GeneratorStatus.done)
g2 := upto(2)
t.eq(g2.next().?, 1)
t.eq(g2.next().?, 2)
t.eq(g2.next() == none, true)

-- A block lambda as the argument of an overload: a `return` without a value does not match the overload that
-- needs a result.
fn pick(x int, f fn(int) -> str) -> str:
    return f(x)
fn pick(x int, f fn(int) -> void) -> str:
    f(x)
    return 'void'
r := pick(5, |x|):
    if x > 3:
        return
    t.eq(x, 1)
t.eq(r, 'void')

--cytest: pass
