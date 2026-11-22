-- The payload of a new result (`f(&a)!`) borrows from the owner of the result.
fn first(scope a &Array[int]) -> scope !&int:
    return &a[0]

fn main() -> !void:
    a := Array[int]{1, 2, 3}
    e := first(&a)!
    a << 4
    print(e.*)

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `a`.
--
--@MainPath():8:5:
--    a << 4
--    ^
--