type Shape enum:
    case circle float
    case circle int

--cytest: error
--CompileError: `circle` has already been declared as a `choice_case`
--
--@MainPath():3:10:
--    case circle int
--         ^~~~~~~~~~
--@MainPath():1:1:
--type Shape enum:
--^~~~~~~~~~~~~~~~
--
