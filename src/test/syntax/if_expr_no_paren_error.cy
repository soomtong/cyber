x := 1
y := if x == 1: 2 else 3

--cytest: error
--ParseError: Expected `(`. An `if` expression is written `if (cond) a else b`.
--
--@MainPath():2:9:
--y := if x == 1: 2 else 3
--        ^
--