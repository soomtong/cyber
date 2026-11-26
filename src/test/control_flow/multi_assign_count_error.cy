a, b := 1, 2
a, b = 3, 4, 5

--cytest: error
--ParseError: 2 places take 2 values, found 3. Write one value for each: `a, b = x, y`.
--
--@MainPath():2:1:
--a, b = 3, 4, 5
--^
--