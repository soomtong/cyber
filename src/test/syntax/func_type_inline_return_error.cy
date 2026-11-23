fn apply(f fn(int) -> ) -> int:
    return f(1)

--cytest: error
--ParseError: Expected return type.
--
--@MainPath():1:23:
--fn apply(f fn(int) -> ) -> int:
--                      ^
--