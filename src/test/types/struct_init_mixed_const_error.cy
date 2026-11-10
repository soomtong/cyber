type A struct:
    x int
    y int

const a = A{3, y = 2}
print(a.x)

--cytest: error
--CompileError: Expected key value pair.
--
--@MainPath():5:13:
--const a = A{3, y = 2}
--            ^
--
