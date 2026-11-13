names := {'a', 'b'}
for n in names:
    print(n)

--cytest: error
--ParseError: Expected `:` or `|x|:`. A `for` loop is written `for xs |x|:` or `for 0..n |i|:`, not `for x in xs:`.
--
--@MainPath():2:7:
--for n in names:
--      ^
--