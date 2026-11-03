use test

-- Inlined bodies may contain loops. `break` and `continue` exit the callee's loops, not the caller's.

fn find_first(xs []int, target int) -> int:
    for 0..xs.len() |i|:
        if xs[i] == target:
            return i
    return -1

fn sum_odd_until(n int, stop int) -> int:
    total := 0
    i := 0
    while i < n:
        i += 1
        if i % 2 == 0:
            continue
        if i > stop:
            break
        total += i
    return total

fn probe(start int, mask int) -> int:
    slot := start
    while:
        slot = (slot + 1) && mask
        if slot % 5 == 0:
            return slot

fn grid(n int) -> int:
    count := 0
    for 0..n |i|:
        for 0..n |j|:
            if j > i:
                break
            if j == 1:
                continue
            count += 1
    return count

fn sum_probes(n int) -> int:
    total := 0
    for 0..n |i|:
        total += probe(i, 15)
    return total

xs := []int{4, 8, 15, 16, 23, 42}
test.eq(find_first(xs, 15), 2)
test.eq(find_first(xs, 99), -1)
test.eq(sum_odd_until(20, 9), 25)
test.eq(sum_odd_until(5, 100), 9)
test.eq(probe(0, 15), 5)
test.eq(probe(13, 15), 15)
test.eq(grid(4), 7)
-- A loop inlined inside another inlined loop.
test.eq(sum_probes(4), 20)

-- The caller's own `break` and `continue` still target the caller's loop.
hits := 0
for 0..10 |k|:
    if find_first(xs, k * 4) == -1:
        continue
    hits += 1
    if sum_odd_until(k, 3) > 3:
        break
test.eq(hits, 3)

n := 0
while:
    n += 1
    if probe(n, 7) == 5:
        break
test.eq(n, 1)

--cytest: pass
