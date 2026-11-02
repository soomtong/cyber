use test

-- Small leaf functions are inlined by the bytecode generator. These cases check that
-- the inlined body behaves like a call.

fn add(a int, b int) -> int:
    return a + b

fn clamp(x int, lo int, hi int) -> int:
    if x < lo:
        return lo
    if x > hi:
        return hi
    return x

fn swap_sum(a int, b int) -> int:
    t := a
    a = b
    b = t
    return a * 10 + b

type Vec:
    x int
    y int

fn mk(x int, y int) -> Vec:
    return Vec{x=x, y=y}

fn (&Vec) bump(n int):
    self.x += n
    self.y += n

fn (&Vec) sum() -> int:
    return self.x + self.y

global hits int = 0

fn hit():
    hits += 1

-- Returns.
test.eq(5, add(2, 3))
test.eq(1, clamp(-5, 1, 9))
test.eq(9, clamp(50, 1, 9))
test.eq(4, clamp(4, 1, 9))
test.eq(21, swap_sum(1, 2))

-- `x = f(x)` reads the old value.
x := 7
x = add(x, x)
test.eq(14, x)

-- Nested in expressions and as arguments.
test.eq(12, add(add(1, 2), add(clamp(100, 0, 5), 4)))

-- Struct return, discarded result, void function, method on a borrowed receiver.
v := mk(3, 4)
test.eq(3, v.x)
test.eq(4, v.y)
_ = mk(1, 1)
_ = add(1, 1)
v.bump(10)
test.eq(27, v.sum())
hit()
hit()
test.eq(2, hits)

-- Inside a loop with locals that outlive the inlined body.
total := 0
for 0..100 |i|:
    total = add(total, clamp(i, 10, 20))
test.eq(1845, total)

-- str values through an inlined function.
fn pick(a str, b str, first bool) -> str:
    if first:
        return a
    return b

test.eq('abc', pick('abc', 'xyz', true))
test.eq('xyz', pick('abc', 'xyz', false))

--cytest: pass
