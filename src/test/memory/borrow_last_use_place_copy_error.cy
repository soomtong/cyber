-- A copy of a container that points into another container (`g2 := g`) points into it too, also after the last use
-- of the original.
type W:
    x int
    q &int

type G:
    p &W

fn run():
    y := 5
    a := Array[int]{1, 2}
    var w W = W{x=42, q=&y}
    var g G = G{p=&w}
    g2 := g
    w.q = &a[0]
    print(g.p.x)
    a << 3
    print(g2.p.q.*)

run()

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `a`.
--
--@MainPath():18:5:
--    a << 3
--    ^
--
