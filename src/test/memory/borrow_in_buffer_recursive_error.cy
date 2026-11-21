-- The element type is not resolved yet when `[]Tree` is: the check waits until `Tree` turns out to hold a borrow.
type Tree:
    kids []Tree
    v    &int

y := 1
t := Tree{kids={}, v=&y}
print(t.v.*)

--cytest: error
--CompileError: `[]Tree` keeps values of the borrow type `Tree` in a buffer, where a borrow is not checked. Use an owned type, `^T` or a vector `[N]T`.
--
--@MainPath():3:10:
--    kids []Tree
--         ^~~~~~
--@MainPath():2:1:
--type Tree:
--^~~~~~~~~~
--