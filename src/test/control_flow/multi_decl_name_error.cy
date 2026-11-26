a, b.c := 1, 2

--cytest: error
--ParseError: Expected identifier for variable declaration.
--
--@MainPath():1:4:
--a, b.c := 1, 2
--   ^
--