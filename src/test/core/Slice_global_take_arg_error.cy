global g []int = {1}
g.append(g.span())

--cytest: error
--CompileError: The method takes `g` out while it runs, so this argument can not read `g`. Read it into a local first.
--
--@MainPath():2:10:
--g.append(g.span())
--         ^~~~~~~~
--