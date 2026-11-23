use test

-- A trait method is implemented by a method with a shared receiver `&T`.
type Counter trait:
    fn inc(n int)
    fn total() -> int

    fn inc_twice(n int):
        self.inc(n)
        self.inc(n)

-- A `&T` receiver writes a field that is not managed.
type Plain:
    with Counter
    n int

fn (&Plain) inc(n int):
    self.n += n

fn (&Plain) total() -> int:
    return self.n

p := Plain{n=1}
var dp &Dyn[Counter] = &p
dp.inc(2)
dp.inc_twice(3)
test.eq(9, p.total())

-- A managed value that the method changes is kept behind a reference.
type Log:
    xs []int

type Logged:
    with Counter
    log ^Log

fn (&Logged) inc(n int):
    self.log.xs += n

fn (&Logged) total() -> int:
    return self.log.xs.len()

var dl ^Dyn[Counter] = ^Logged{log=^Log{xs={}}}
dl.inc(1)
dl.inc_twice(2)
test.eq(3, dl.total())

-- With a `&T` and a `&&T` overload, the trait takes the `&T` one. The `&&T` one is called on the type.
type Both:
    with Counter
    xs []int
    n  int

fn (&&Both) inc(n int):
    self.xs += n

fn (&Both) inc(n int):
    self.n += n

fn (&Both) total() -> int:
    return self.n

b := Both{xs={}, n=0}
var db &Dyn[Counter] = &b
db.inc(5)
test.eq(5, b.total())
test.eq(0, b.xs.len())

-- A `scope &T` receiver is a shared borrow.
type First trait:
    fn first() -> scope &int

type Nums:
    with First
    xs []int

fn (scope &Nums) first() -> scope &int:
    return &self.xs[0]

nums := Nums{xs={7, 8}}
var df &Dyn[First] = &nums
test.eq(7, df.first().*)

-- A method that takes the receiver by value implements the trait for a template constraint.
type Sized trait:
    fn size() -> int

type Unit:
    with Sized
    n int

fn (Unit) size() -> int:
    return self.n

fn size_of[T Sized](x T) -> int:
    return x.size()

test.eq(4, size_of[Unit](Unit{n=4}))

--cytest: pass
