for ['a.py'] |f|:
    print(f)

--cytest: error
--ParseError: Expected `Vector` element type. A list literal uses braces: `{a, b}` or `[]T{a, b}`.
--
--@MainPath():1:14:
--for ['a.py'] |f|:
--             ^
--