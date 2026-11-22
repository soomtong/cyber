-- A function can not store a borrow of one parameter behind another one: the caller does not know that the value
-- now borrows it. Declare the parameter `scope` to let the caller check it.
type H:
    b &int

fn store(h &&H, p &int):
    h.b = p

y := 5
var h H = H{b=&y}
if true:
    z := 42
    store(&&h, &z)
print(h.b.*)

--cytest: error
--CompileError: The value behind `h` can not outlive `p`.
--
--@MainPath():7:11:
--    h.b = p
--          ^
--
