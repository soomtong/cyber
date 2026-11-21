-- A local that a branch moved is dead after the `if` statement.
type R struct:
    with NoCopy
    id int

fn take(r R):
    pass

a := R{id=1}
if a.id == 1:
    take(a)
print(a.id)

--cytest: error
--CompileError: `a` was moved at 11:10. Borrow it with `&a` or clone it to use it here.
--
--@MainPath():12:7:
--print(a.id)
--      ^
--