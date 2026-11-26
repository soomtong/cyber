-- The same as `borrow_last_use_place_late_error.cy`, with the borrow stored by a method that takes it as its `scope`
-- argument.
type W:
    x int
    q &int

type G:
    p ?&W

fn (&&G) set(scope p &W):
    self.p = p

fn run():
    y := 5
    a := Array[int]{1, 2}
    var w W = W{x=42, q=&y}
    var g G = G{p=none}
    g.set(&w)
    w.q = &a[0]
    print(w.x)
    a << 3
    print(g.p.?.q.*)

run()

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `a`.
--
--@MainPath():21:5:
--    a << 3
--    ^
--