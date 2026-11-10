type R struct:
    with NoCopy
    id int

x := R{id=1}
a := Array[R]{x}

--cytest: error
--CompileError: Cannot copy `R`, type implements `NoCopy`.
--
--@MainPath():6:15:
--a := Array[R]{x}
--              ^
--
