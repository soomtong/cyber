use test

-- An exclusive borrow that a local, a parameter or a borrow container holds is checked where it is used. The use is
-- allowed when no other local borrows from the same owner.
type Foo:
    xs []int

fn (&&Foo) grow():
    self.xs.append(1)

fn (&Foo) size() -> int:
    return self.xs.len()

type Holder:
    r &&Foo

fn (&&Holder) push(n int):
    self.r.xs.append(n)

fn take(r &&Foo):
    r.xs.append(9)

f := Foo{xs={1, 2, 3}}
begin:
    -- Copies of one borrow point to the same value.
    r := &&f
    r2 := r
    take(r2)
    r.grow()
    take(r)
    r2.grow()
    test.eq(7, r.size())
begin:
    -- A borrow read through a borrow container.
    h := Holder{r=&&f}
    h.push(1)
    h.r.grow()
    p := &&h
    p.push(2)
    p.r.grow()
test.eq(11, f.size())

fn foo(r &&Foo):
    begin:
        r2 := r
        r.grow()
        r2.grow()
    -- The borrow ends with its block.
    begin:
        s := &r.xs[0]
        test.eq(1, s.*)
    r.grow()
    -- A loop can read through `self`, and write a value that is not managed.
    sum := 0
    for r.xs |x|:
        sum += r.size()
        r.xs[0] = x
    test.eq(14 * 14, sum)
    r.xs = {1}
    r.* = Foo{xs={5}}
foo(&&f)
test.eq(5, f.xs[0])

-- A function template takes the borrow the same way.
fn push(x %T, a &&Array[T]):
    a.append(x)

fn fill(a &&Array[int]):
    push(5, a)
    begin:
        s := &a[0]
        test.eq(1, s.*)
    push(6, a)
arr := Array[int]{1, 2, 3}
fill(&&arr)
push(7, &&arr)
test.eq(6, arr.len())

-- A value that is not managed is written in place. A borrow of it reads the new value.
x := 1
c := &x
x = 7
test.eq(7, c.*)

type Pair:
    a int
    b int
pr := Pair{a=1, b=2}
pa := &pr.a
pr.a = 5
pr = Pair{a=6, b=7}
test.eq(6, pa.*)

-- A managed value can be assigned after the borrow ended.
g := Foo{xs={1}}
begin:
    s := &g.xs[0]
    test.eq(1, s.*)
g.xs = {7}
g = Foo{xs={8}}
test.eq(8, g.xs[0])

-- A borrow assigned to `_` ends with its statement.
fn (scope &&Foo) add(n int) -> scope &&Foo:
    self.xs.append(n)
    return self

fn build(r &&Foo):
    _ = r.add(1).add(2)
    _ = r.add(3)
    r.grow()
bf := Foo{xs={}}
build(&&bf)
test.eq(4, bf.xs.len())

-- A borrow into one field is no conflict with a write to another field.
type Reg:
    items []int
    names []str
    name str

fn (&&Reg) rename():
    for self.items |k|:
        self.names[0] = 'x'
        self.name = 'y'
        self.names.append('z')

reg := Reg{items={1, 2}, names={'a'}, name='a'}
begin:
    first := &reg.items[0]
    reg.name = 'b'
    reg.names[0] = 'c'
    test.eq(1, first.*)
reg.rename()
test.eq(3, reg.names.len())
test.eq('y', reg.name)

-- A borrow of a place stays valid when the value in the place is replaced. It reads the new value.
t := 'abc'
ts := &t
t = 'zzz'
test.eq('zzz', ts.*)
begin:
    rv := &reg
    reg.name = 'q'
    test.eq('q', rv.name)

--cytest: pass
