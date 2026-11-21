-- A local that the left operand of `or` moved is dead in the right operand.
type R struct:
    with NoCopy
    id int

fn take(r R) -> bool:
    return r.id > 0

a := R{id=1}
ok := take(a) or take(a)

--cytest: error
--CompileError: `a` was moved at 10:12. Borrow it with `&a` or clone it to use it here.
--
--@MainPath():10:23:
--ok := take(a) or take(a)
--                      ^
--