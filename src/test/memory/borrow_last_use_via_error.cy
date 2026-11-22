-- A container keeps its borrows while a borrow of it is alive, also after the last statement that names it. A copy
-- that is read through the borrow (`hr.b`) can not outlive what the container borrows.
type H:
    a &int
    b &int

fn run():
    y := 5
    var r &int = &y
    if true:
        z := 42
        if true:
            var h H = H{a=&y, b=&y}
            hr := &h
            h.b = &z
            r = hr.b
    print(r.*)

run()

--cytest: error
--CompileError: `r` can not outlive `z`.
--
--@MainPath():16:17:
--            r = hr.b
--                ^~~~
--
