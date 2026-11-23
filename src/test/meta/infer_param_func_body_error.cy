fn main():
    a := []%T{}

--cytest: error
--CompileError: `%T` can only be declared in the signature of a function.
--
--@MainPath():2:12:
--    a := []%T{}
--           ^~
--
