type Color enum:
    case red
    case red

--cytest: error
--CompileError: `red` has already been declared as a `enum_case`
--
--@MainPath():3:10:
--    case red
--         ^~~
--@MainPath():1:1:
--type Color enum:
--^~~~~~~~~~~~~~~~
--
