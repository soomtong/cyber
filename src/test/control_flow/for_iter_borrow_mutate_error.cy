a := Array[int]{1, 2}
for a |&e|:
    a << 3

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `a`.
--
--@MainPath():3:5:
--    a << 3
--    ^
--
