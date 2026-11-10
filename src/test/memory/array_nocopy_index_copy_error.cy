type R struct:
    with NoCopy
    id int

a := Array[R]{R{id=1}}
x := a[0]

--cytest: error
--CompileError: Cannot copy `R`, type implements `NoCopy`.
--
--@MainPath():6:6:
--x := a[0]
--     ^~~~
--
