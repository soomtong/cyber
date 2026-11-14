for p |s| in {'a', 'b'}:
    print(s)

--cytest: error
--ParseError: A `for` loop has no `in`. The values come first and the name goes in `|x|`: `for {'a', 'b'} |s|:`.
--
--@MainPath():1:11:
--for p |s| in {'a', 'b'}:
--          ^
--