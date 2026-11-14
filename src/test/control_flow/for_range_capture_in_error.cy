for 0..3 |i| in xs:
    print(i)

--cytest: error
--ParseError: A `for` loop has no `in`. The values come first and the name goes in `|x|`: `for xs |i|:`.
--
--@MainPath():1:14:
--for 0..3 |i| in xs:
--             ^
--