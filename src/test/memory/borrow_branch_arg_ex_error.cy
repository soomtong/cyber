-- The same for an exclusive borrow before the argument, and for `?else`.
fn f(b &&Array[int], r &int) -> int:
    b << 4
    return r.*

a := Array[int]{1, 2, 3}
var o ?&int = none
print(f(&&a, o ?else &a[0]))

--cytest: error
--CompileError: Cannot pass an exclusive borrow of `a` with another argument that borrows `a`.
--
--@MainPath():8:9:
--print(f(&&a, o ?else &a[0]))
--        ^~~
--