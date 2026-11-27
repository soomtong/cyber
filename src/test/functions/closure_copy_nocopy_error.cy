type Res:
    with NoCopy
    id int

fn main():
    r := Res{id=1}
    f := fn() -> int => r.id

--cytest: error
--CompileError: A lambda captures a copy of a local, but `r` of the type `Res` can not be copied (`NoCopy`). Declare it with `^T`, or borrow it before the lambda (`b := &r`) and use `b` in the lambda.
--
--@MainPath():7:25:
--    f := fn() -> int => r.id
--                        ^
--
