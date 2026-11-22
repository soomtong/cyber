-- A borrow from one of the cases of a `switch` that an element takes is a loan of every owner.
a := Array[int]{1, 2, 3}
y := 7
rs := [1]&int{&y}
k := 1
rs[0] = switch k:
    case 2 => &y
    else => &a[0]
a << 4
print(rs[0].*)

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `a`.
--
--@MainPath():9:1:
--a << 4
--^
--