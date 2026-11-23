fn apply(f fn int -> int) -> int:
    return f(1)

--cytest: error
--ParseError: Expected open parenthesis.
--
--@MainPath():1:15:
--fn apply(f fn int -> int) -> int:
--              ^
--