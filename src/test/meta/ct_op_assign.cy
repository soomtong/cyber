use test

-- Compound assignment at compile-time must match the runtime result (F-20).
fn f() -> int:
    t := 10
    t += 5
    t -= 2
    t *= 3
    t /= 3
    return t

fn g() -> int:
    total := 0
    for 0..10 |i|:
        total += i
    return total

fn h() -> int:
    v := [3]int(1)
    v[1] = 2
    v[1] += 40
    v[0] -= v[1]
    return v[0] + v[1]

test.eq(13, f())
test.eq(45, g())
test.eq(1, h())

const x = f()
const y = g()
const z = h()
test.eq(13, x)
test.eq(45, y)
test.eq(1, z)

--cytest: pass
