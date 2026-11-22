-- A `scope` parameter that is passed by value is a copy that ends with the call. A borrow of a place in it can not
-- be returned.
type H:
    a &int
    x int

fn mk(scope h H) -> scope &int:
    return &h.x

y := 5
r := mk(H{a=&y, x=42})
print(r.*)

--cytest: error
--CompileError: Expected to return a borrow from the same scope as `h`.
--
--@MainPath():8:5:
--    return &h.x
--    ^~~~~~~~~~~
--
