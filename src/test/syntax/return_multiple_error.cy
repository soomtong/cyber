fn f() -> int:
    return 1, 2

--cytest: error
--ParseError: A function returns one value. Declare a tuple type and return that: `type Pair(a int, b int)`, `fn f() -> Pair:`, `return {1, 2}`.
--
--@MainPath():2:13:
--    return 1, 2
--            ^
--
