use test

-- `?!int(x)` calls the type `?!int`. It is not `?(!int(x))`.
a := ?!int(int.parse('12'))
test.eq(a.?!, 12)

s := 'x'
a = ?!int(int.parse(s))
test.eq(a.? !else -1, -1)

a = ?!int(none)
test.eq(a == none, true)

fn unwrap(a ?!int) -> int:
    if a |r|:
        return r !else -1
    return -2

test.eq(unwrap(?!int(int.parse('7'))), 7)
test.eq(unwrap(?!int(int.parse('x'))), -1)
test.eq(unwrap(none), -2)

fn make(s str) -> ?!int:
    return ?!int(int.parse(s))

test.eq(make('5').?!, 5)

m := Map[str, ?!int]{}
m['a'] = ?!int(int.parse('3'))
test.eq(m['a'].?!, 3)

-- The element type of a slice or vector ends before the initializer.
b := []!int{int.parse('1'), int.parse('x')}
test.eq(b.len(), 2)
test.eq(b[0]!, 1)
test.eq(b[1] !else 9, 9)

c := [2]!int{int.parse('4'), int.parse('x')}
test.eq(c[0]!, 4)
test.eq(c[1] !else 9, 9)

d := []?int{1, none}
test.eq(d.len(), 2)
test.eq(d[0].?, 1)
test.eq(d[1] == none, true)

e := []?!int{none, none}
test.eq(e.len(), 2)

-- `!` on a value is still logic not, and it takes the call.
fn is_big(x int) -> bool:
    return x > 1

test.eq(!is_big(1), true)
test.eq(!is_big(2), false)
f := ?bool(is_big(2))
test.eq(f.?, true)

--cytest: pass
