x := 3
switch x:
    case ..5: pass
    else: pass

--cytest: error
--CompileError: Expected a range with a start and an end.
--
--@MainPath():3:10:
--    case ..5: pass
--         ^~~
--