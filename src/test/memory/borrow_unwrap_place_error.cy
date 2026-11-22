-- An unwrap capture of an option that holds a borrow of a place in another container stays inside the container.
type W:
    x int
    q &int

type H:
    a &int
    o ?&int

z := 2
y := 5
var r &int = &y
if true:
    w := W{x=42, q=&z}
    var h H = H{a=&y, o=none}
    h.o = &w.x
    if h.o |q|:
        r = q
print(r.*)

--cytest: error
--CompileError: `r` can not outlive `h`.
--
--@MainPath():18:13:
--        r = q
--            ^
--
