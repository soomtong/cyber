try:
    print('a')
print('b')

--cytest: error
--ParseError: Expected else block.
--
--@MainPath():3:1:
--print('b')
--^
--
