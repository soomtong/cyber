-- A copy that is stored in a field can not outlive what the container borrows (nested, option).
type Inner:
    b ?&int

type H:
    inner Inner

type O:
    b ?&int

x := 7
var o O = O{b=&x}
if true:
    y := 5
    h := H{inner=Inner{b=&y}}
    o.b = h.inner.b
print(o.b.?.*)

--cytest: error
--CompileError: `o` can not outlive `y`.
--
--@MainPath():16:11:
--    o.b = h.inner.b
--          ^~~~~~~~~
--
