-- A value that borrows a container without a parent (`k.p = &g`) keeps it from ending after its last use, so `g` keeps
-- `w` and `w` keeps its borrow of `a`.
type W:
    x int
    q &int

type G:
    p ?&W

type K:
    p ?&G

fn run():
    y := 5
    a := Array[int]{1, 2}
    var w W = W{x=42, q=&y}
    var g G = G{p=none}
    g.p = &w
    var k K = K{p=none}
    k.p = &g
    w.q = &a[0]
    print(w.x)
    print(g.p.?.x)
    a << 3
    print(k.p.?.p.?.q.*)

run()

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `a`.
--
--@MainPath():24:5:
--    a << 3
--    ^
--