-- A container that holds a borrow of a place in another container keeps a copy that is read out of it inside.
type W:
    x int
    q &int

type H:
    b &int

z := 1
var r &int = &z
if true:
    w := W{x=2, q=&z}
    h := H{b=&w.x}
    r = h.b
print(r.*)

--cytest: error
--CompileError: `r` can not outlive `h`.
--
--@MainPath():14:9:
--    r = h.b
--        ^~~
--
