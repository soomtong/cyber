-- The same for a generic function whose argument borrows one of several owners.
fn f(%T type, r &T, b &&Array[T]) -> T:
    b << 4
    return r.*

fn run(k int):
    a := Array[int]{1, 2, 3}
    y := 7
    print(f(int, if (k == 2) &y else &a[0], &&a))

run(1)

--cytest: error
--CompileError: Cannot pass an exclusive borrow of `a` with another argument that borrows `a`.
--
--@MainPath():9:45:
--    print(f(int, if (k == 2) &y else &a[0], &&a))
--                                            ^~~
--
