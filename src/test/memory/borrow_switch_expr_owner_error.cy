-- A borrow that a `switch` expression gives borrows from the owner of its case.
a := Array[int]{1, 2, 3}
x := 1
e := switch x:
    case 1 => &a[0]
    else => &a[1]
a << 4
print(e.*)

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `a`.
--
--@MainPath():7:1:
--a << 4
--^
--