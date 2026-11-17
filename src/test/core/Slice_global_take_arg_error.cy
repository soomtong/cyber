global g []int = {1}
g.append(g.len())

--cytest: error
--CompileError: The method takes `g` out while it runs, so an argument can not read `g`. Read it into a local first.
--
--@MainPath():2:10:
--g.append(g.len())
--         ^~~~~~~
--