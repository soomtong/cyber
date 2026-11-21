-- An `if` unwrap statement moves a `NoCopy` option that it reads from a variable.
type R struct:
    with NoCopy
    id int

fn mk() -> ?R:
    return R{id=1}

fn f():
    o := mk()
    if o |v|:
        pass
    if o |v|:
        pass

f()

--cytest: error
--CompileError: `o` was moved at 11:8. Borrow it with `&o` or clone it to use it here.
--
--@MainPath():13:8:
--    if o |v|:
--       ^
--