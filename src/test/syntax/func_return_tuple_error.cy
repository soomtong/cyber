fn f() -> (int, int):
    return 1, 2

--cytest: error
--ParseError: A return type can not list several types. Declare a tuple type and return that: `type Pair(a int, b int)`, `fn f() -> Pair:`, `return {1, 2}`.
--
--@MainPath():1:11:
--fn f() -> (int, int):
--          ^
--
