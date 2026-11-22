-- A borrow of a case capture ends with the case.
type Slot enum:
    case num int
    case one &int

x := 7
sl := Slot.num(3)
t := switch sl:
    case .num |n| => &n
    else => &x
print(t.*)

--cytest: error
--CompileError: The result of `switch` can not outlive `n`.
--
--@MainPath():9:22:
--    case .num |n| => &n
--                     ^~
--