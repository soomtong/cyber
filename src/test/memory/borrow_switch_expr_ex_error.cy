-- An exclusive borrow that a `switch` expression gives keeps exclusive access.
a := Array[int]{1, 2, 3}
x := 1
e := switch x:
    case 1 => &&a
    else => &&a
a << 5
e << 6

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `a`.
--
--@MainPath():7:1:
--a << 5
--^
--