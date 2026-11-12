use test

-- A fiber of a `scope` block borrows values that are declared before the block.
fn deep(n int) -> int:
    if n == 0:
        return 0
    var pad [16]int = [16]int(0)
    return pad[0] + 1 + deep(n - 1)

fn add(out &int, n int):
    suspend
    out.* += n
    suspend
    out.* += n

type P:
    x int
    y int

fn addp(p &P, n int):
    out := &p.y
    suspend
    out.* += n
    _ = deep(200)
    suspend
    p.x += n

fn work(total &int) -> !void:
    p := P{x = 0, y = 0}
    scope |s|:
        s.start(add, {total, 1})
        s.start(addp, {&p, 5})
        -- The stack moves while the fibers hold borrows of it and did not start yet.
        _ = deep(3000)
        s.join()!
        s.start(add, {total, 10})
        s.start(addp, {&p, 7})
        _ = deep(20000)
    test.eq(12, p.x)
    test.eq(12, p.y)

total := 0
work(&total)!
test.eq(22, total)

-- A fiber of a block has a block of its own. Its stack moves while its fibers borrow from it.
fn leaf(out &int, mine &int, n int):
    suspend
    out.* += n
    mine.* += n
    suspend
    out.* += n
    mine.* += n

fn mid(out &int, n int) -> !void:
    mine := 0
    scope |s|:
        s.start(leaf, {out, &mine, n})
        s.start(leaf, {out, &mine, n})
        suspend
        _ = deep(2000)
    test.eq(n * 4, mine)

total = 0
scope |s|:
    s.start(mid, {&total, 1})
    s.start(mid, {&total, 2})
    _ = deep(5000)
test.eq(12, total)

-- The borrows end with the block.
fn push(a &&Array[int], n int):
    suspend
    a << n

arr := Array[int]{}
scope |s|:
    s.start(push, {&&arr, 1})
scope |s|:
    s.start(push, {&&arr, 2})
arr << 3
test.eq(3, arr.len())

-- A borrow of a global, and one value borrowed by the fibers of two blocks.
global g int = 5

fn read(a &int, sum &int):
    suspend
    sum.* += a.*

sum := 0
x := 1
scope |s|:
    s.start(read, {&g, &sum})
    scope |s2|:
        s2.start(read, {&x, &sum})
        s.start(read, {&x, &sum})
test.eq(7, sum)

--cytest: pass
