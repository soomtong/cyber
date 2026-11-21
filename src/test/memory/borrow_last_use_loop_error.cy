-- A borrow that a loop names after the resize lives through the whole loop.
a := Array[int]{1, 2, 3}
elem := &a[2]
for 0..2 |i|:
    a << 4
    print(elem.*)

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `a`.
--
--@MainPath():5:5:
--    a << 4
--    ^
--