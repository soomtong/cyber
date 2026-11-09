try:
    print('a')
else |1|:
    print('b')

--cytest: error
--ParseError: Expected error variable.
--
--@MainPath():3:7:
--else |1|:
--      ^
--
