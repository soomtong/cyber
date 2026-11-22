-- A copy of a container that holds a borrow of a place in another container can not outlive the container.
type W:
    x int
    q &int

type H:
    b &int

z := 1
var r H = H{b=&z}
if true:
    w := W{x=2, q=&z}
    h := H{b=&w.x}
    r = h
print(r.b.*)

--cytest: error
--CompileError: `r` can not outlive `h`.
--
--@MainPath():14:9:
--    r = h
--        ^
--
