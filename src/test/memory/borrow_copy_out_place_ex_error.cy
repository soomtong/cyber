-- A container that was borrowed exclusively can hold a borrow of a place in another container.
type W:
    x int
    q &int

type H:
    b &int

fn put(h &&H, scope p &int):
    h.b = p

fn run():
    z := 1
    x := 3
    u := 4
    var r &int = &u
    if true:
        w := W{x=2, q=&x}
        var h H = H{b=&z}
        put(&&h, &w.x)
        r = h.b
    print(r.*)

run()

--cytest: error
--CompileError: `r` can not outlive `h`.
--
--@MainPath():21:13:
--        r = h.b
--            ^~~
--
