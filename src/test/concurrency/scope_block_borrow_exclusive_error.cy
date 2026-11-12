fn show(a &Array[int]):
    suspend

a := Array[int]{}
scope |s|:
    s.start(show, {&a})
    a << 1

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `a`.
--
--@MainPath():7:5:
--    a << 1
--    ^
--