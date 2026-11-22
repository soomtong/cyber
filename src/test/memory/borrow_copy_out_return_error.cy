-- A copy that is read out of a container can not be returned past a local that the container borrows.
type H:
    a &int
    b &int

fn pick(scope p &int) -> scope &int:
    y := 5
    h := H{a=p, b=&y}
    return h.b

x := 1
print(pick(&x).*)

--cytest: error
--CompileError: Expected to return a borrow from the same scope as `p`.
--
--@MainPath():9:5:
--    return h.b
--    ^~~~~~~~~~
--
