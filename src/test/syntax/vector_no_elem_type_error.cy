x := [3]

--cytest: error
--ParseError: Expected the element type of `[n]T`. A list literal uses braces: `{a, b}` or `[]T{a, b}`.
--
--@MainPath():1:9:
--x := [3]
--        ^
--