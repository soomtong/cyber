use test

-- Regression (findings F-73): a `&&self` method that appends to an `Array` field, with or without
-- a field before it, used to lose elements or crash.

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

--cytest: pass
