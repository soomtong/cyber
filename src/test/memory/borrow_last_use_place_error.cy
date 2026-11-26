-- A container that holds a borrow of another container (`g` of `&w`) keeps that container from ending after its last
-- use, so the borrows that it gets later (`w.q = &a[0]`) stay.
type W:
    x int
    q &int

type G:
    p &W

fn run():
    y := 5
    a := Array[int]{1, 2}
    var w W = W{x=42, q=&y}
    g := G{p=&w}
    w.q = &a[0]
    a << 3
    print(g.p.q.*)

run()

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `a`.
--
--@MainPath():16:5:
--    a << 3
--    ^
--
