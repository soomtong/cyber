use test

-- Inlined bodies can inline small calls again, up to a depth limit.

fn sign(x int) -> int:
    if x < 0:
        return -1
    else x == 0:
        return 0
    else:
        return 1

fn abs_sign(x int) -> int:
    if sign(x) < 0:
        return -x
    else:
        return x

fn twice_abs(x int) -> int:
    return abs_sign(x) + abs_sign(x)

fn count_down(n int) -> int:
    if n == 0:
        return 0
    return 1 + count_down(n - 1)

test.eq(sign(-5), -1)
test.eq(sign(0), 0)
test.eq(sign(7), 1)
test.eq(abs_sign(-3), 3)
test.eq(twice_abs(-4), 8)
test.eq(twice_abs(6), 12)

-- An if/else inside nested inlines exits the right block.
total := 0
for -3..4 |i|:
    if sign(i) == 0:
        total += 100
    else:
        total += twice_abs(i)
test.eq(total, 124)

-- Recursion is not inlined into itself.
test.eq(count_down(10), 10)

-- `Map` set and get go through nested inlines.
m := Map[int, int]{}
for 0..100 |i|:
    m[i] = i * 2
for 0..100 |i|:
    m[i] = m[i] + 1
test.eq(m.size(), 100)
test.eq(m[50], 101)

s := Map[str, int]{}
for 0..50 |i|:
    s['k%{i}'] = i
s['k3'] = 33
test.eq(s.size(), 50)
test.eq(s['k3'], 33)
test.eq(s['k49'], 49)

--cytest: pass
