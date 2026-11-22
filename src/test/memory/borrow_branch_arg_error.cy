-- An argument that borrows from one of two owners borrows both, so it can not go next to an exclusive borrow of either.
fn f(r &int, b &&Array[int]) -> int:
    b << 4
    return r.*

a := Array[int]{1, 2, 3}
y := 7
k := 1
print(f(if (k == 2) &y else &a[0], &&a))

--cytest: error
--CompileError: Cannot pass an exclusive borrow of `a` with another argument that borrows `a`.
--
--@MainPath():9:36:
--print(f(if (k == 2) &y else &a[0], &&a))
--                                   ^~~
--