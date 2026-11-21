use test

-- `s.xs = s.xs.appended(v)` reuses the buffer of the member: the statement is the in-place call. Also through the
-- `&&T` receiver of a method. See `docs/decisions/project_last_use.md` "남은 다섯".

type S struct:
    xs []int
    n  int

type T struct:
    s S

fn (&&S) add(v int) -> bool:
    p := as[int] self.xs.ptr
    self.xs = self.xs.appended(v)
    return p == as[int] self.xs.ptr

fn run():
    s := S{xs=[]int{1, 2, 3}, n=0}
    s.xs = s.xs.appended(4)
    s.xs = s.xs.appended(4)
    p := as[int] s.xs.ptr
    s.xs = s.xs.appended(4)
    test.eq(true, p == as[int] s.xs.ptr)
    s.xs = s.xs.removed(0)
    test.eq(true, p == as[int] s.xs.ptr)
    s.xs = s.xs.inserted(0, 9)
    test.eq(true, p == as[int] s.xs.ptr)
    s.xs = s.xs + []int{7}
    test.eq(true, p == as[int] s.xs.ptr)
    test.eq(true, s.add(5))
    test.eq(8, s.xs.len())
    test.eq(9, s.xs[0])
    test.eq(5, s.xs[7])

    -- A member of a member.
    t := T{s=S{xs=[]int{1}, n=0}}
    t.s.xs = t.s.xs.appended(2)
    t.s.xs = t.s.xs.appended(2)
    q := as[int] t.s.xs.ptr
    t.s.xs = t.s.xs.appended(2)
    test.eq(true, q == as[int] t.s.xs.ptr)

    -- Another value that shares the buffer is unchanged.
    ys := s.xs
    s.xs = s.xs.appended(6)
    test.eq(8, ys.len())
    test.eq(9, s.xs.len())

    -- The last element: the member does not share the buffer after it.
    zs := s.xs
    s.xs = s.xs.removed(8)
    test.eq(9, zs.len())
    test.eq(8, s.xs.len())
    test.eq(false, as[int] zs.ptr == as[int] s.xs.ptr)

    -- The arguments name the variable: the list is copied as before.
    s.xs = s.xs.appended(s.xs.len())
    test.eq(9, s.xs.len())
    test.eq(8, s.xs[8])

run()

--cytest: pass
