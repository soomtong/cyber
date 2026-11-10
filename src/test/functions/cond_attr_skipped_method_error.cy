type R struct:
    with NoCopy
    id int

type Box[T Any] struct:
    x T

#[cond=type.is_copyable(T)]
fn (&Box[]) dup() -> T:
    return self.x

r := Box[R]{x=R{id=7}}
r.dup()

--cytest: error
--CompileError: Can not find the symbol `dup` in `Box[R]`.
--
--@MainPath():13:3:
--r.dup()
--  ^~~
--
