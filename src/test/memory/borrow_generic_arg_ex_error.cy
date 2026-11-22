-- A generic function call checks its arguments like any call: an exclusive borrow of `a` can not be passed next to a
-- borrow of an element of `a`, since the callee can grow `a` and free the element.
fn f(%T type, r &T, b &&Array[T]) -> T:
    b << 4
    return r.*

a := Array[int]{1, 2, 3}
print(f(int, &a[0], &&a))

--cytest: error
--CompileError: Cannot pass an exclusive borrow of `a` with another argument that borrows `a`.
--
--@MainPath():8:21:
--print(f(int, &a[0], &&a))
--                    ^~~
--
