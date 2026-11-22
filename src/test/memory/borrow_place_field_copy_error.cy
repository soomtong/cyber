-- The same holds when the borrow of the place is stored in a field after the declaration.
type W:
    x int
    q &int

type H:
    b &int

z := 1
var r H = H{b=&z}
if true:
    w := W{x=2, q=&z}
    var h H = H{b=&z}
    h.b = &w.x
    r = h
print(r.b.*)

--cytest: error
--CompileError: `r` can not outlive `h`.
--
--@MainPath():15:9:
--    r = h
--        ^
--
