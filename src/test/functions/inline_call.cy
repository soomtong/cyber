use test

-- Small functions that make calls are inlined one level deep. The calls inside stay calls.

global log str = ''

fn note(s str) -> int:
    log = log + s
    return s.len()

fn twice(a str, b str) -> int:
    return note(a) + note(b)

fn fib(n int) -> int:
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)

fn safe_div(a int, b int) -> int:
    if b == 0:
        return 0
    return a / b

-- Calls inside the inlined body keep their order.
test.eq(twice('ab', 'c'), 3)
test.eq(log, 'abc')

-- A recursive function inlines one level of itself.
test.eq(fib(20), 6765)

test.eq(safe_div(7, 2), 3)
test.eq(safe_div(7, 0), 0)

-- `Array.append` calls `ensure_cap` when full.
arr := Array[int]{}
for 0..100 |i|:
    arr.append(i)
sum := 0
for 0..arr.len() |i|:
    sum += arr[i]
test.eq(sum, 4950)
arr[3] = 30
test.eq(arr[3], 30)

-- Managed values through an inlined body that calls.
strs := Array[str]{}
for 0..20 |i|:
    strs.append('s%{i}')
test.eq(strs[19], 's19')
test.eq(strs.len(), 20)

--cytest: pass
