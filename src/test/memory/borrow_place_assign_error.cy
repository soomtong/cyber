-- A container that is assigned a borrow of a place in another container can not outlive that container.
type W:
    x int
    q &int

type H:
    b &int

z := 1
var h H = H{b=&z}
if true:
    w := W{x=2, q=&z}
    h = H{b=&w.x}
print(h.b.*)

--cytest: error
--CompileError: `h` can not outlive `w`.
--
--@MainPath():13:9:
--    h = H{b=&w.x}
--        ^~~~~~~~~
--
