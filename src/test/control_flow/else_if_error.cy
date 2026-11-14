a := true
if a:
    print(1)
else if a:
    print(2)

--cytest: error
--ParseError: Expected a condition or `:`. Write `else cond:`, not `else if cond:`.
--
--@MainPath():4:6:
--else if a:
--     ^
--