type R struct:
    with NoCopy
    id int

a := Array[R]{R{id=1}}
for a |r|:
    pass

--cytest: error
--CompileError: Cannot copy `R`, type implements `NoCopy`.
--
--@MainPath():6:8:
--for a |r|:
--       ^
--
