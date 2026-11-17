use t 'test'

-- `p.* = r` with a local `r` that holds a managed value copies it. Before, the local and the target released
-- the same value at the end of the function, and the target read freed memory (F-161).
fn set_ptr(p Ptr[[]int]):
    r := []int{1, 2}
    p.* = r
    t.eq(2, r.len())

fn set_borrow(p &[]str):
    r := []str{'a' + 'b'}
    p.* = r
    t.eq('ab', r[0])

fn set_ex_borrow(p &&[]str):
    r := []str{'c' + 'd', 'e' + 'f'}
    p.* = r
    t.eq('cd', r[0])

xs := []int{9}
set_ptr(*xs)
t.eq(2, xs.len())
t.eq(2, xs[1])

ss := []str{'x' + 'y'}
set_borrow(&ss)
t.eq('ab', ss[0])
set_ex_borrow(&&ss)
t.eq(2, ss.len())
t.eq('ef', ss[1])

-- `pop` on a `[]T`.
ps := []str{'p' + '1', 'p' + '2'}
t.eq('p2', ps.pop().?)
t.eq(1, ps.len())
t.eq('p1', ps.pop().?)
t.eq(true, ps.pop() == none)

--cytest: pass
