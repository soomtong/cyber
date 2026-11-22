-- A `!&T` local holds the borrow like a `?&T` local.
fn first(scope a &Array[int]) -> scope !&int:
    return &a[0]

a := Array[int]{1, 2, 3}
r := first(&a)
a << 4
print((r !else &a[1]).*)

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `a`.
--
--@MainPath():7:1:
--a << 4
--^
--