-- A copy that is read through a borrow of a container (`gr.p` of `gr := &g`) points where the borrows of the container
-- point: into `w`, which keeps its later borrows.
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
    gr := &g
    r := gr.p
    w.q = &a[0]
    print(g.p.x)
    a << 3
    print(r.q.*)

run()

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `a`.
--
--@MainPath():19:5:
--    a << 3
--    ^
--
