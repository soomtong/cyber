use test

-- A `return` in the body of a lambda that infers its return type returns the type of the body.
f := fn(x str) => int.parse(x) !else:
    return 0
test.eq(5, f('5'))
test.eq(0, f('a'))

-- A bare `return` for a `void` body.
fn note(x str) -> !void:
    if x == 'bad':
        return error.Bad
count := ^0
v := fn(x str) => note(x) !else:
    count.* += 1
    return
v('ok')
v('bad')
test.eq(1, count.*)

-- With a `!` that leaves the lambda, the return type is `!U` and the `return` wraps its value.
fn half(x int) -> !int:
    if x % 2 != 0:
        return error.Odd
    return x / 2
h := fn(x str) => half(int.parse(x)!) !else:
    return -7
test.eq(2, h('4')!)
test.eq(-7, h('3')!)
test.eq(error.InvalidCharacter, h('z').unwrap_error())

-- The `!` is in the value of the `return`.
g := fn(x str) => int.parse(x) !else:
    return int.parse('5')! + 1
test.eq(3, g('3')!)
test.eq(6, g('z')!)
g2 := fn(x str, y str) => int.parse(x) !else:
    return int.parse(y)!
test.eq(4, g2('z', '4')!)
test.eq(-1, g2('z', 'z') !else -1)

-- A `scope` block in the body: an error of its fibers leaves the lambda like a failing `!`.
fn job(x int) -> !void:
    if x == 0:
        return error.Zero
fn scoped() -> !void:
    s := fn(x int) => job(0) !else:
        scope |sc|:
            sc.start(job, {x})
        return
    s(1)!
    test.eq(error.Zero, s(0).unwrap_error())
scoped()!

--cytest: pass