fn foo[]():
    pass

--cytest: error
--ParseError: Expected `::` and a name after the parent type.
--
--@MainPath():1:4:
--fn foo[]():
--   ^
--
