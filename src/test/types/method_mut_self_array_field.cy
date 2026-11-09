use test

-- Regression (findings F-73): taking the address of a field through an exclusive borrow (`&&T`)
-- used the address of the register holding the borrow instead of the borrow itself. A `&&self`
-- method that appends to an `Array` field lost elements or crashed. The inlined call path was
-- fixed first (`38272a0c`), so the bodies below are long enough to stay out of line as well.

type Items:
    items Array[int]

type Bag:
    n int
    items Array[int]
    tail int

fn (&&Items) push(x int):
    self.items << x

fn (&&Bag) push(x int):
    self.items << x
    self.tail = x

a := Items{items=Array[int]{}}
a.push(1)
a.push(2)
a.push(3)
test.eq(3, a.items.len())
test.eq(2, a.items[1])

b := Bag{n=7, items=Array[int]{}, tail=0}
b.push(10)
b.push(20)
b.push(30)
test.eq(3, b.items.len())
test.eq(30, b.items[2])
test.eq(7, b.n)
test.eq(30, b.tail)

-- Not inlined: the body is too large for the inline cost limit.
fn (&&Bag) push_many(x int):
    self.items << x
    self.items << (x + 1)
    self.items << (x + 2)
    self.items << (x + 3)
    self.items << (x + 4)
    self.items << (x + 5)
    self.items << (x + 6)
    self.items << (x + 7)
    self.items << (x + 8)
    self.items << (x + 9)
    self.tail = x + 9

c := Bag{n=7, items=Array[int]{}, tail=0}
c.push_many(1)
c.push_many(11)
c.push_many(21)
test.eq(30, c.items.len())
test.eq(1, c.items[0])
test.eq(30, c.items[29])
test.eq(7, c.n)
test.eq(30, c.tail)

-- A plain `&&T` parameter, not inlined.
fn fill(d &&Items, x int):
    d.items << x
    d.items << (x + 1)
    d.items << (x + 2)
    d.items << (x + 3)
    d.items << (x + 4)
    d.items << (x + 5)
    d.items << (x + 6)
    d.items << (x + 7)
    d.items << (x + 8)
    d.items << (x + 9)

e := Items{items=Array[int]{}}
fill(&&e, 1)
fill(&&e, 11)
test.eq(20, e.items.len())
test.eq(20, e.items[19])

-- A nested field behind `&&self`, not inlined.
type Outer:
    n int
    inner Items

fn (&&Outer) push_many(x int):
    self.inner.items << x
    self.inner.items << (x + 1)
    self.inner.items << (x + 2)
    self.inner.items << (x + 3)
    self.inner.items << (x + 4)
    self.inner.items << (x + 5)
    self.inner.items << (x + 6)
    self.inner.items << (x + 7)
    self.inner.items << (x + 8)
    self.inner.items << (x + 9)

o := Outer{n=5, inner=Items{items=Array[int]{}}}
o.push_many(1)
o.push_many(11)
test.eq(20, o.inner.items.len())
test.eq(20, o.inner.items[19])
test.eq(5, o.n)

-- A `&&T` stored in a struct field: the fields behind it must not be folded into the holder's layout.
type Holder:
    r &&Items

fn (&&Holder) push(x int):
    self.r.items << x

f := Items{items=Array[int]{}}
h := Holder{r=&&f}
h.push(1)
h.push(2)
h.push(3)
test.eq(3, f.items.len())
test.eq(3, f.items[2])

--cytest: pass
