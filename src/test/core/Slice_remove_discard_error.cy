out := []str{'a', ''}
while out.len() > 0 and out.last().trim() == '':
    _ = out.remove(out.len() - 1)

--cytest: error
--CompileError: The result of `remove` is the new list, and `out` keeps the old one. Write `out = out.remove(out.len() - 1)`.
--
--@MainPath():3:9:
--    _ = out.remove(out.len() - 1)
--        ^~~~~~~~~~~~~~~~~~~~~~~~~
--
