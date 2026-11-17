out := []str{'a', ''}
while out.len() > 0 and out.last().trim() == '':
    _ = out.removed(out.len() - 1)

--cytest: error
--CompileError: `removed` returns a new list and leaves `out` as it was. To change `out` in place, write `out.remove(out.len() - 1)`.
--
--@MainPath():3:9:
--    _ = out.removed(out.len() - 1)
--        ^~~~~~~~~~~~~~~~~~~~~~~~~~
--