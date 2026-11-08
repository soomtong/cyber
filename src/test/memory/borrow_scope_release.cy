use test

-- A borrow stored in a local ends with its block. A borrow passed as an argument ends with its statement.
-- See `docs/decisions/project_borrow_model.md`.

fn peek(a &Array[int]) -> int:
    return a.len()

-- Temporary borrow in a call, then an exclusive method call.
a := Array[int]{1, 2, 3}
test.eq(3, peek(&a))
a.append(4)
test.eq(4, a.len())

-- Borrow local in an inner block.
if true:
    r := &a
    test.eq(4, r.len())
a.append(5)
test.eq(5, a.len())

-- Element borrow in an inner block.
if true:
    elem := &a[0]
    elem.* = 10
a.append(6)
test.eq(10, a[0])

-- Exclusive borrow local in an inner block, then a shared borrow.
if true:
    ex := &&a
    ex.append(7)
r := &a
test.eq(7, r.len())

-- A copy of a borrow local borrows the same owner. Both end with the block.
b := Array[int]{1}
if true:
    r1 := &b
    r2 := r1
    test.eq(1, r2.len())
b.append(2)
test.eq(2, b.len())

-- The loop borrows the iterable only while it runs.
sum := 0
for b |x|:
    sum += x
b.append(3)
test.eq(3, sum)
test.eq(3, b.len())

-- Reassigning a borrow to a value declared at the same depth.
x := 1
y := 2
ref := &x
ref = &y
test.eq(2, ref.*)

--cytest: pass
