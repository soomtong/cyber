use t 'test'

-- A lambda keeps a copy of a local from when it is created.
a := 123
read_a := fn() -> int => a
a = 5
t.eq(read_a(), 123)
t.eq(a, 5)

-- A copy of a `str`, a struct and an option.
type Field:
    name str
    max  float

name := 'wid' + 'th'
field := Field{name=name, max=10.0}
limit := ?float(2.5)
check := fn(x float) -> str:
    low := limit ?else 0.0
    if x < low or x > field.max:
        return '%{name}: no'
    return '%{field.name}: ok'
name = 'other'
t.eq(check(3.0), 'width: ok')
t.eq(check(30.0), 'width: no')

-- A closure that leaves the function that made it.
fn adder(n int) -> Func[fn(int) -> int]:
    return |x| x + n

add3 := adder(3)
t.eq(add3(4), 7)
t.eq(adder(10)(1), 11)

-- Each closure made in a loop keeps the value of its own round.
var fs []Func[fn() -> int] = {}
for 0..3 |i|:
    fs += fn() -> int => i * 10
var got []int = {}
for fs |f|:
    got += f()
t.eq_slice({0, 10, 20}, got)

-- A slice copy shares the elements, like any copy of a slice, but keeps its own length.
words := []str{'a', 'bb'}
total := fn() -> int:
    n := 0
    for words |w|:
        n += w.len()
    return n
words += 'ccc'
t.eq(total(), 3)

-- `self` of a value method.
type Counter:
    n int

fn (Counter) label() -> str:
    f := fn() -> str => 'n=%{self.n}'
    return f()

t.eq(Counter{n=3}.label(), 'n=3')

-- A comparator for `sort`.
weights := []int{30, 10, 20}
order := []int{0, 1, 2}
order.sort(|x, y| weights[x] < weights[y])
t.eq_slice({1, 2, 0}, order)

-- Copies next to `^T` captures and more than one copy.
shared := ^1
b, c, d := 2, 3, 4
sum := fn() -> int => shared.* + b + c + d
shared.* = 10
b = 0
t.eq(sum(), 19)

-- Copies next to a borrow: the pinned closure owns the copies.
fn rank(names []str) -> []str:
    m := Map[str, int]{app=7, db=8, web=23}
    counts := &m
    tag := 'k' + 'ey'
    sorted := names[..]
    sorted.sort(|x, y| counts[x] > counts[y] and tag.len() == 3)
    return sorted

t.eq_slice({'web', 'db', 'app'}, rank({'app', 'web', 'db'}))

--cytest: pass
