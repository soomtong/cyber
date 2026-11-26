-- A copy that is read through a borrow of a container that holds a borrow of a place in a local (`hr.b`) can point
-- into that local, and a `scope` function can not return it.
type W:
    x int
    q &int

type H:
    a &int
    b &int

fn get(scope p &int) -> scope &int:
    w := W{x=1, q=p}
    h := H{a=p, b=&w.x}
    hr := &h
    r := hr.b
    return r

y := 5
print(get(&y).*)

--cytest: error
--CompileError: Expected to return a borrow from the same scope as `p`.
--
--@MainPath():16:5:
--    return r
--    ^~~~~~~~
--
