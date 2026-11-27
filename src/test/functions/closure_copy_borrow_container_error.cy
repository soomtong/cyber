type View:
    n &int

fn main():
    x := 1
    v := View{n=&x}
    f := fn() -> int => v.n.*

--cytest: error
--CompileError: A lambda captures a copy of a local, but `v` of the type `View` holds borrows. Declare it with `^T`, or borrow it before the lambda (`b := &v`) and use `b` in the lambda.
--
--@MainPath():7:25:
--    f := fn() -> int => v.n.*
--                        ^
--
