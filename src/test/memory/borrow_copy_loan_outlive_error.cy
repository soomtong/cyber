-- A copy of a borrow container can not outlive a borrow that was stored in the container later. It crashed the
-- compiler at the end of the block before.
type H:
    a &int
    b &int

fn run():
    y := 5
    var r H = H{a=&y, b=&y}
    if true:
        z := 2
        if true:
            var h H = H{a=&y, b=&y}
            h.b = &z
            r = h
    print(r.b.*)
run()

--cytest: error
--CompileError: `r` can not outlive `z`.
--
--@MainPath():15:17:
--            r = h
--                ^
--
