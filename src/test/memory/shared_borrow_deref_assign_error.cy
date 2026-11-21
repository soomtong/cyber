-- `p.* = v` of a shared borrow replaces the managed value that `p` borrows.
fn set(p &[]int):
    p.* = {9}

xs := []int{1, 2, 3}
s := &xs[0]
set(&xs)
print(s.*)

--cytest: error
--CompileError: Cannot replace a managed value through a shared borrow. Declare the borrow as `&&T`.
--
--@MainPath():3:5:
--    p.* = {9}
--    ^~~~~~~~~
--