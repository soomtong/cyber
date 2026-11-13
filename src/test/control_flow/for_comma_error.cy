for 'a', 'b', 'c' |p|:
    print(p)

--cytest: error
--ParseError: Expected `:` or `|x|:`. To loop over values, put them in a list literal: `for {a, b} |x|:`.
--
--@MainPath():1:8:
--for 'a', 'b', 'c' |p|:
--       ^
--