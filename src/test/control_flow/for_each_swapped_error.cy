for f |{'a', 'b'}|:
    print(f)

--cytest: error
--ParseError: Expected a variable name in `|x|`. The values come first and the name goes in `|x|`: `for {a, b} |x|:`.
--
--@MainPath():1:8:
--for f |{'a', 'b'}|:
--       ^
--
