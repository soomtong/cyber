-- The result of `!else` can give the borrow.
fn first(scope a &Array[int]) -> scope !&int:
    return &a[0]

y := 7
a := Array[int]{1, 2, 3}
e := first(&a) !else &y
a << 4
print(e.*)

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `a`.
--
--@MainPath():8:1:
--a << 4
--^
--