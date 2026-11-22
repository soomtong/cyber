-- A borrow that is stored through a borrow keeps its owner borrowed.
fn run():
    y := 5
    a := Array[int]{1, 2}
    var r &int = &y
    pp := &r
    pp.* = &a[0]
    a << 4
    print(r.*)

run()

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `a`.
--
--@MainPath():8:5:
--    a << 4
--    ^
--
