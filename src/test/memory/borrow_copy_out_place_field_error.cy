-- A borrow of a place in another container that is stored in a field later keeps a copy that is read out inside.
type W:
    x int
    q &int

type H:
    b &int

fn run():
    z := 1
    var r &int = &z
    if true:
        w := W{x=2, q=&z}
        var h H = H{b=&z}
        h.b = &w.x
        r = h.b
    print(r.*)

run()

--cytest: error
--CompileError: `r` can not outlive `h`.
--
--@MainPath():16:13:
--        r = h.b
--            ^~~
--
