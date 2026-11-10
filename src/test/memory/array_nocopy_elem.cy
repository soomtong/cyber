use test

-- An `Array` can hold elements that can not be copied (F-26). Elements are moved in, read by borrow and
-- destructed once. See `docs/decisions/project_array_nocopy_elem.md`.

global deinits int = 0

type R struct:
    with NoCopy
    id int

fn (&R) @deinit():
    deinits += 1

-- Empty literal, `append`, `<<`.
if true:
    a := Array[R]{}
    a.append(R{id=1})
    a << R{id=2}
    test.eq(2, a.len())
    test.eq(2, a[1].id)
    r := &a[0]
    test.eq(1, r.id)
    test.eq(0, deinits)
test.eq(2, deinits)

-- A literal moves its elements. A variable is moved with `move`.
deinits = 0
if true:
    x := R{id=20}
    a := Array[R]{move x, R{id=21}, R{id=22}}
    test.eq(3, a.len())
    test.eq(20, a[0].id)
    test.eq(22, a[2].id)
    test.eq(0, deinits)
test.eq(3, deinits)

-- A literal in a loop.
deinits = 0
for 0..3 |i|:
    a := Array[R]{R{id=i}}
    test.eq(i, a[0].id)
test.eq(3, deinits)

-- A literal as a return value, and a moved array.
fn make(n int) -> Array[R]:
    return {R{id=n}, R{id=n + 1}}

deinits = 0
if true:
    a := make(5)
    test.eq(6, a[1].id)
    b := move a
    test.eq(2, b.len())
    test.eq(0, deinits)
test.eq(2, deinits)

-- Assigning to an index destructs the old element and moves the new one in.
deinits = 0
if true:
    a := Array[R]{R{id=1}, R{id=2}}
    a[0] = R{id=5}
    test.eq(1, deinits)
    test.eq(5, a[0].id)
    a[1].id = 7
    test.eq(7, a[1].id)
test.eq(3, deinits)

-- `insert`, `remove`, `size_down`, `clear`.
deinits = 0
if true:
    a := Array[R]{R{id=1}, R{id=2}, R{id=3}}
    a.insert(0, R{id=9})
    test.eq(9, a[0].id)
    test.eq(0, deinits)
    a.remove(1)
    test.eq(1, deinits)
    test.eq(2, a[1].id)
    a.size_down(2)
    test.eq(2, deinits)
    a.clear()
    test.eq(4, deinits)
    test.eq(0, a.len())
test.eq(4, deinits)

-- Growth moves the elements.
deinits = 0
if true:
    a := Array[R]{}
    for 0..20 |i|:
        a << R{id=i}
    test.eq(0, deinits)
    test.eq(19, a[19].id)
test.eq(20, deinits)

-- Iteration by borrow.
deinits = 0
if true:
    a := Array[R]{R{id=1}, R{id=2}, R{id=3}}
    sum := 0
    for a |&r|:
        sum += r.id
    test.eq(6, sum)
    sum = 0
    for a |i, &r|:
        sum += i * r.id
    test.eq(8, sum)
    for a |&r|:
        if r.id == 1:
            continue
        sum = r.id
        break
    test.eq(2, sum)
    test.eq(0, deinits)
test.eq(3, deinits)

-- A span of the array borrows the elements.
if true:
    a := Array[R]{R{id=1}, R{id=2}}
    s := a[..]
    test.eq(2, s.len())
    test.eq(2, s[1].id)

-- A struct that holds a `NoCopy` member is not copyable either.
type W struct:
    r R
    n int

deinits = 0
if true:
    a := Array[W]{W{r=R{id=1}, n=2}}
    a << W{r=R{id=3}, n=4}
    test.eq(4, a[1].n)
    test.eq(3, a[1].r.id)
test.eq(2, deinits)

-- An array of arrays.
if true:
    a := Array[Array[int]]{{1}, {2, 3}}
    a << Array[int]{4, 5, 6}
    a << {7}
    test.eq(4, a.len())
    test.eq(2, a[1].len())
    test.eq(6, a[2][2])
    a[0] = {8, 9}
    test.eq(9, a[0][1])
    total := 0
    for a |&e|:
        total += e.len()
    test.eq(8, total)

-- Iteration by borrow of copyable elements copies nothing.
type C struct:
    n int

fn (&C) @deinit():
    deinits += 1

if true:
    a := Array[C]{}
    a << C{n=1}
    a << C{n=2}
    deinits = 0
    sum := 0
    for a |&c|:
        sum += c.n
    test.eq(3, sum)
    test.eq(0, deinits)

-- A `Slice` iterates by borrow too.
if true:
    s := []str{'a', 'bc'}
    n := 0
    for s |&e|:
        n += e.len()
    test.eq(3, n)
    for s |i, &e|:
        n += i + e.len()
    test.eq(7, n)

--cytest: pass