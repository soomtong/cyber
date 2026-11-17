global g []int = {}
g.append(1)

--cytest: error
--CompileError: A global can not be borrowed exclusively, so a method can not change `g` in place. Assign a new list: `g = g + v` (or `appended`, `removed`, `inserted`), or keep the list in a local.
--
--@MainPath():2:1:
--g.append(1)
--^
--