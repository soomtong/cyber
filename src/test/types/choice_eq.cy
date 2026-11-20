use test
use json

type Shape enum:
    case circle float
    case square int
    case point

type Pt:
    x int
    y int

type Wrap enum:
    case name str
    case pt   Pt
    case opt  ?int
    case list []int

-- Same case: the payloads are compared with `==`.
a := Shape.circle(1.5)
test.eq(true, a == Shape.circle(1.5))
test.eq(false, a == Shape.circle(2.0))
test.eq(true, a != Shape.circle(2.0))

-- Different cases are never equal.
test.eq(false, a == Shape.square(1))
test.eq(true, a != Shape.point)

-- A case without a payload.
test.eq(true, Shape.point == Shape.point)

-- Payloads that compare by value.
test.eq(true, Wrap.name('ab') == Wrap.name('a' + 'b'))
test.eq(true, Wrap.pt(Pt{x=1, y=2}) == Wrap.pt(Pt{x=1, y=2}))
test.eq(false, Wrap.pt(Pt{x=1, y=2}) == Wrap.pt(Pt{x=1, y=3}))
test.eq(true, Wrap.opt(none) == Wrap.opt(none))
test.eq(false, Wrap.opt(3) == Wrap.opt(none))

-- A slice payload compares like a slice: by reference.
xs := []int{1, 2}
w := Wrap.list(xs)
test.eq(true, w == Wrap.list(xs))
test.eq(false, w == Wrap.list([]int{1, 2}))

-- An optional choice.
s := ?Shape(Shape.point)
test.eq(false, s == none)
test.eq(true, s == Shape.point)
n := ?Shape(none)
test.eq(true, n == none)

-- json.Value is a choice.
v := json.parse('{"a": 1}')!
test.eq(false, v.get('a') == none)
test.eq(true, v.get('b') == none)
test.eq(true, json.Value.int(1) == json.Value.int(1))
test.eq(false, json.Value.int(1) == json.Value.float(1.0))

--cytest: pass