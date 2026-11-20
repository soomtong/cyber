use test

-- A borrow taken through a local that holds a borrow is a reborrow. It is allowed while it lasts no longer than its
-- statement.
type Foo:
    xs []int

fn (&&Foo) grow():
    self.xs.append(1)

fn (&Foo) size() -> int:
    return self.xs.len()

fn take(r &&Foo):
    r.xs.append(9)

f := Foo{xs={1, 2, 3}}
begin:
    r := &&f
    r.xs.append(1)
    r.grow()
    test.eq(5, r.xs.len())
    test.eq(5, r.size())
    test.eq(1, r.xs[0])
    -- The loop borrows through `r` until it ends.
    sum := 0
    for r.xs |x|:
        sum += x
    test.eq(8, sum)
    -- A copy of the borrow is no new borrow.
    r2 := r
    take(r2)
    test.eq(6, r.size())

-- A shared borrow through a shared borrow can be kept.
begin:
    a := &f
    c := &a.xs[0]
    test.eq(1, c.*)

-- A borrow of a borrow container borrows the container.
type Holder:
    r &&Foo

fn (&&Holder) push(n int):
    self.r.xs.append(n)

begin:
    h := Holder{r=&&f}
    h.push(1)
    p := &&h
    p.push(2)
test.eq(8, f.xs.len())

--cytest: pass
