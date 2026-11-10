type R struct:
    with NoCopy
    id int

a := Array[R]{R{id=1}}
a.last()

--cytest: error
--CompileError: Can not find the symbol `last` in `Array[R]`.
--
--@MainPath():6:3:
--a.last()
--  ^~~~
--
