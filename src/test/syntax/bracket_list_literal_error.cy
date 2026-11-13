for ['a.py', 'b.py'] |f|:
    print(f)

--cytest: error
--ParseError: A list literal uses braces: `{a, b}` or `[]T{a, b}`.
--
--@MainPath():1:12:
--for ['a.py', 'b.py'] |f|:
--           ^
--