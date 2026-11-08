use test

-- F-10. Growing the VM stack moves it when the allocator cannot resize in place. Stack pointers (`&x`) held by
-- a frame are patched from the pointer layout recorded at the call site. The main frame and the indirect calls
-- (`call_ptr`, `call_union`, `call_trait`) used to be skipped and read the freed stack afterwards.

fn rec(n int) -> int:
    if n == 0: return 0
    k := 0
    while k < 1:
        k += 1
    return rec(n - 1) + k

-- Main frame borrow across a deep direct call.
x := 42
p := &x
test.eq(rec(20000), 20000)
test.eq(p.*, 42)

-- Borrow passed down every level and read at the bottom.
fn rec_p(n int, p &int) -> int:
    if n == 0: return p.*
    k := 0
    while k < 1:
        k += 1
    return rec_p(n - 1, p) + k

test.eq(rec_p(20000, &x), 20042)

type Fn1 = fn(int) -> int

-- `call_union`.
fn via_union(f Func[Fn1], p &int) -> int:
    z := 0
    while z < 1:
        z += 1
    r := f(20000)
    return r + p.* + z

test.eq(via_union(rec, &x), 20043)

-- `call_ptr`.
fn via_ptr(f Fn1, p &int) -> int:
    z := 0
    while z < 1:
        z += 1
    r := f(20000)
    return r + p.* + z

test.eq(via_ptr(rec, &x), 20043)

-- `call_trait`.
type Deep trait:
    fn go() -> int

type D:
    with Deep
    n int

fn (&D) go() -> int:
    return rec(self.n)

fn via_trait(d &Dyn[Deep], p &int) -> int:
    z := 0
    while z < 1:
        z += 1
    r := d.go()
    return r + p.* + z

d := D{n=20000}
test.eq(via_trait(&d, &x), 20043)

--cytest: pass
