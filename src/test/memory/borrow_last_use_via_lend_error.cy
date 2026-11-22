-- A borrow that is stored in a container keeps its owner borrowed while a borrow of the container is alive.
type H:
    a &int
    b &int

fn run():
    y := 5
    a := Array[int]{1, 2}
    var h H = H{a=&y, b=&y}
    hr := &h
    h.b = &a[0]
    a << 4
    print(hr.b.*)

run()

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `a`.
--
--@MainPath():12:5:
--    a << 4
--    ^
--
