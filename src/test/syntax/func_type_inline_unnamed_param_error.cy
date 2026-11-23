fn apply(fn(int) -> int) -> int:
    return 1

--cytest: error
--ParseError: Expected parameter name.
--
--@MainPath():1:10:
--fn apply(fn(int) -> int) -> int:
--         ^
--