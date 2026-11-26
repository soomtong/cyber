a, b := 1, 2
a, b += 1, 2

--cytest: error
--ParseError: Expected `=` or `:=` after the list of variables. `+=` and the other compound assignments take one variable.
--
--@MainPath():2:6:
--a, b += 1, 2
--     ^
--