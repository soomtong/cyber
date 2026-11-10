x := 1
switch x:
    case 1 |a|:
        pass
    else:
        pass

--cytest: error
--CompileError: Only a case of a choice can capture a payload.
--
--@MainPath():3:13:
--    case 1 |a|:
--            ^
--
