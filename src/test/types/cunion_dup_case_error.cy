type U cunion:
    case a int
    case a float

--cytest: error
--CompileError: `a` has already been declared as a `union_case`
--
--@MainPath():3:5:
--    case a float
--    ^~~~~~~~~~~~
--@MainPath():1:1:
--type U cunion:
--^~~~~~~~~~~~~~
--
