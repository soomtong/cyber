use test

-- `Array.append` and `Array.insert` move the value into the buffer and growth moves the elements,
-- so a destructor runs once per element, when the array dies. See `docs/decisions/project_array_append_move.md`.

global deinits int = 0

type Res:
    name str
fn (&Res) @deinit():
    deinits += 1

if true:
    a := Array[Res]{}
    for 0..9 |i|:
        a.append(Res{name='r%{i}'})
    -- The capacity grew at 8 (4 -> 8 -> 16) without destructing the moved elements.
    test.eq(0, deinits)
    test.eq(9, a.len())
    a.insert(0, Res{name='first'})
    a.insert(5, Res{name='middle'})
    test.eq(0, deinits)
    test.eq(11, a.len())
test.eq(11, deinits)

-- A local passed by value is copied, so it stays usable.
deinits = 0
if true:
    a := Array[Res]{}
    r := Res{name='x'}
    a.append(r)
    test.eq('x', r.name)
    a.append(move r)
    test.eq(2, a.len())
test.eq(2, deinits)

-- Insert keeps the order and shifts the tail.
b := Array[int]{2, 4}
b.insert(0, 1)
b.insert(2, 3)
b.insert(4, 5)
test.eq_span(b[..], {1, 2, 3, 4, 5})

-- Reference elements are retained into the array.
c := Array[^int]{}
c.append(^1)
x := ^2
c.append(x)
c.insert(0, ^0)
test.eq(2, x.*)
test.eq(0, c[0].*)
test.eq(1, c[1].*)
test.eq(2, c[2].*)

-- `clone` copies the elements into an independent array.
d := b.clone()
d.append(6)
test.eq(5, b.len())
test.eq(6, d.len())
test.eq(6, d[5])
e := Array[int]{}
f := e.clone()
test.eq(0, f.len())
f.append(1)
test.eq(1, f.len())

-- `ArrayStore.append(span)` appends the span once.
s := ArrayStore[int]{1, 2}
other := [2]int{10, 20}
s.append(other[..])
test.eq(4, s.len())
test.eq(10, s[2])
test.eq(20, s[3])

--cytest: pass
