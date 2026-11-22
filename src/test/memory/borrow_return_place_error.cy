-- A `scope` function can not return a container that holds a borrow of a place in one of its locals.
type W:
    x int
    q &int

type H:
    a &int
    b &int

fn mk(scope p &int) -> scope H:
    w := W{x=42, q=p}
    h := H{a=p, b=&w.x}
    return h

y := 5
h := mk(&y)
print(h.b.*)

--cytest: error
--CompileError: Expected to return a borrow from the same scope as `p`.
--
--@MainPath():13:5:
--    return h
--    ^~~~~~~~
--
