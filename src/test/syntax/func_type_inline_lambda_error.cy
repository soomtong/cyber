-- A function type with a body is a lambda. Its parameters need names.
f := fn([]int) -> int:
    return 1

--cytest: error
--ParseError: Expected parameter name.
--
--@MainPath():2:9:
--f := fn([]int) -> int:
--        ^
--