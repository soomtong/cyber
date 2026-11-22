global G Array[int] = {1, 2, 3}
type A:
    arr Array[int] = G
a := A{}

--cytest: error
--CompileError: Cannot copy `Array[int]`, type implements `NoCopy`.
--
--@MainPath():3:22:
--    arr Array[int] = G
--                     ^
--
