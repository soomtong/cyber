use test

-- Records in registers. A field of a value local, and a pointer param of an inlined callee whose
-- arg is `&local`, read and write the local's registers directly instead of going through `addr`.

type Vec:
    x int
    y int

type Line:
    a Vec
    b Vec

type Flags:
    a bool
    b bool
    n int

fn (&Vec) sum() -> int:
    return self.x + self.y

fn (&Vec) sum2() -> int:
    return self.sum() * 2

fn (&Vec) scale(k int):
    self.x *= k
    self.y *= k

fn (&Vec) grow() -> int:
    self.x += 5
    return self.x * 2

fn swap(v &Vec) -> Vec:
    return Vec{x=v.y, y=v.x}

fn rot(v &Vec) -> Vec:
    return Vec{x=v.y, y=v.x + v.y}

fn id_ptr(p Ptr[int]) -> Ptr[int]:
    return p

fn pick(p &int, q &int, first bool) -> int:
    if !first:
        p = q
    return p.*

fn through(p Ptr[int]) -> int:
    pp := *p
    return pp.*.*

fn next_val(i &int, n int) -> ?int:
    if i.* >= n:
        return none
    v := i.*
    i.* += 1
    return v

fn (&Flags) set():
    self.a = true
    self.n = 3

-- Fields of a value local.
v := Vec{x=1, y=2}
test.eq(3, v.x + v.y)
v.x = 5
test.eq(5, v.x)
v = Vec{x=v.y, y=v.x}
test.eq(2, v.x)
test.eq(5, v.y)
w := v
w.y = 9
test.eq(5, v.y)
test.eq(9, w.y)

-- Nested fields.
l := Line{a=Vec{x=1, y=2}, b=Vec{x=3, y=4}}
l.b.y = 40
test.eq(40, l.b.y)
l.a = Vec{x=l.b.y, y=l.b.x}
test.eq(40, l.a.x)
test.eq(3, l.a.y)
test.eq(3, l.b.x)

-- `&local` args bound to the local.
test.eq(43, l.a.sum())
test.eq(86, l.a.sum2())
v.scale(3)
test.eq(6, v.x)
test.eq(15, v.y)
v.x = v.grow()
test.eq(22, v.x)
v = swap(&v)
test.eq(15, v.x)
test.eq(22, v.y)
v = rot(&v)
test.eq(22, v.x)
test.eq(37, v.y)

-- An inlined `return {…}` into a temp (an rvalue, a declared local) writes its fields directly.
test.eq(37, swap(&v).x)
test.eq(96, rot(&v).sum())
test.eq(59, 22 + swap(&v).x)
s := rot(&v)
test.eq(37, s.x)
test.eq(59, s.y)
test.eq(22, v.x)

-- The param used as a pointer value.
n := 1
q := id_ptr(*n)
q.* = 9
test.eq(9, n)
test.eq(9, through(*n))

-- A param that is reassigned in the body is still a pointer.
a := 10
b := 20
test.eq(10, pick(&a, &b, true))
test.eq(20, pick(&a, &b, false))

-- Option results through `while`.
i := 0
total := 0
while next_val(&i, 4) |val|:
    total += val
test.eq(6, total)
test.eq(4, i)

-- Packed fields still go through memory.
f := Flags{a=false, b=false, n=0}
f.set()
test.eq(true, f.a)
test.eq(false, f.b)
test.eq(3, f.n)

--cytest: pass
